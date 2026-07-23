// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Thin, binary-safe subprocess wrapper around the HarmonyOS Device
/// Connector. One implementation serves DevEco emulators, USB devices,
/// and TCP-connected devices because hdc exposes all of them as targets.
public struct Hdc: Sendable {
    public let binaryPath: String
    public let defaultTimeout: TimeInterval

    public init(binaryPath: String? = nil, defaultTimeout: TimeInterval = 30) {
        self.binaryPath = binaryPath ?? Self.discover()
        self.defaultTimeout = defaultTimeout
    }

    public struct Target: Equatable, Sendable {
        public let connectKey: String
        public let connection: String
        public let state: String
        public let name: String

        public var isOnline: Bool {
            state.caseInsensitiveCompare("Connected") == .orderedSame
                || state.caseInsensitiveCompare("Ready") == .orderedSame
        }
    }

    public struct RunResult: Equatable, Sendable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32

        public var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        public var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    public static func discover(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let override = env["SIM_USE_HDC"], !override.isEmpty { return override }

        var candidates: [String] = []
        for key in ["OHOS_SDK_HOME", "HARMONYOS_SDK_HOME", "DEVECO_SDK_HOME"] {
            guard let root = env[key], !root.isEmpty else { continue }
            candidates.append("\(root)/toolchains/hdc")
            candidates.append("\(root)/openharmony/toolchains/hdc")
            candidates.append("\(root)/default/openharmony/toolchains/hdc")
        }
        candidates.append("/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
        candidates.append("/Applications/DevEco Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")

        if let home = env["HOME"], !home.isEmpty {
            let sdkRoot = "\(home)/Library/Huawei/Sdk/openharmony"
            if let versions = try? fileManager.contentsOfDirectory(atPath: sdkRoot) {
                for version in versions.sorted().reversed() {
                    candidates.append("\(sdkRoot)/\(version)/toolchains/hdc")
                }
            }
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "hdc"
    }

    public func targets() throws -> [Target] {
        let result = try run(args: ["list", "targets", "-v"])
        return Self.parseTargets(result.stdoutString)
    }

    @discardableResult
    public func shell(target: String, args: [String], timeout: TimeInterval? = nil) throws -> RunResult {
        try run(args: ["-t", target, "shell"] + args, timeout: timeout)
    }

    @discardableResult
    public func receive(target: String, remotePath: String, localPath: String) throws -> RunResult {
        try run(args: ["-t", target, "file", "recv", remotePath, localPath])
    }

    @discardableResult
    public func run(args: [String], timeout: TimeInterval? = nil) throws -> RunResult {
        let process = Process()
        let resolvedPath = Self.resolveOnPATH(binaryPath) ?? binaryPath
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); stdout.append(data); lock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); stderr.append(data); lock.unlock()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            let nsError = error as NSError
            let missing = (nsError.domain == NSCocoaErrorDomain && nsError.code == 4)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            if missing { throw HarmonyOSError.hdcMissing(path: resolvedPath) }
            throw HarmonyOSError.transport("Failed to spawn hdc: \(error.localizedDescription)")
        }

        let effectiveTimeout = timeout ?? defaultTimeout
        if exited.wait(timeout: .now() + effectiveTimeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.5)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw HarmonyOSError.timeout(command: args.joined(separator: " "), seconds: effectiveTimeout)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        stdout.append(stdoutTail)
        stderr.append(stderrTail)
        let result = RunResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        lock.unlock()

        let message = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
        let logicalFailure = message.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Fail]")
        }
        guard result.exitCode == 0, !logicalFailure else {
            throw HarmonyOSError.commandFailed(
                command: args.joined(separator: " "),
                exitCode: result.exitCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    public static func parseTargets(_ output: String) -> [Target] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let columns = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let connectKey = columns.first, !connectKey.isEmpty else { return nil }
            guard connectKey.caseInsensitiveCompare("[Empty]") != .orderedSame else { return nil }
            if columns.count == 1 {
                return Target(connectKey: connectKey, connection: "", state: "Connected", name: connectKey)
            }
            if columns.count == 2 {
                return Target(connectKey: connectKey, connection: "", state: columns[1], name: connectKey)
            }
            let connection = columns[1]
            let state = columns[2]
            let reportedName = columns.count > 3 ? columns[3] : connectKey
            let name = reportedName == "localhost" ? connectKey : reportedName
            return Target(connectKey: connectKey, connection: connection, state: state, name: name)
        }
    }

    static func resolveOnPATH(
        _ name: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard !name.contains("/") else { return nil }
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

public enum HarmonyOSError: LocalizedError, Equatable {
    case hdcMissing(path: String)
    case timeout(command: String, seconds: TimeInterval)
    case commandFailed(command: String, exitCode: Int32, message: String)
    case targetNotFound(String)
    case targetUnavailable(connectKey: String, state: String)
    case malformedOutput(String)
    case unsupported(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .hdcMissing(let path):
            return "HarmonyOS hdc was not found at '\(path)'. Install the DevEco Studio or HarmonyOS command-line SDK, add hdc to PATH, or set SIM_USE_HDC to its absolute path."
        case .timeout(let command, let seconds):
            return "hdc command timed out after \(seconds)s: \(command)"
        case .commandFailed(let command, let code, let message):
            let status = code == 0 ? "reported failure" : "failed (exit \(code))"
            return "hdc command \(status): \(command)\(message.isEmpty ? "" : ": \(message)")"
        case .targetNotFound(let target):
            return "HarmonyOS target '\(target)' was not found. Run `sim-use harmonyos devices` and verify USB/TCP debugging authorization."
        case .targetUnavailable(let key, let state):
            return "HarmonyOS target '\(key)' is \(state), not connected."
        case .malformedOutput(let message):
            return "HarmonyOS tool returned malformed output: \(message)"
        case .unsupported(let message), .transport(let message):
            return message
        }
    }
}
