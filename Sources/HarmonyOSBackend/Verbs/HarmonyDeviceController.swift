// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// High-level HarmonyOS operations built entirely on SDK-provided hdc,
/// UITest, and uinput commands. No device-side bridge application is needed.
public final class HarmonyDeviceController {
    public let hdc: Hdc

    public init(hdc: Hdc = Hdc()) {
        self.hdc = hdc
    }

    public static func cacheKey(for connectKey: String) -> String {
        "harmonyos:\(connectKey)"
    }

    public func listTargets() throws -> [Hdc.Target] {
        try hdc.targets()
    }

    public func listUnifiedDevices(onlineOnly: Bool = false) throws -> [Device] {
        let targets = try listTargets()
        let filtered = onlineOnly ? targets.filter(\.isOnline) : targets
        return filtered.map { target in
            Device(
                udid: target.connectKey,
                name: target.name,
                platform: .harmonyos,
                state: target.state,
                runtime: "HarmonyOS"
            )
        }
    }

    public func ping(connectKey: String) throws {
        _ = try hdc.shell(target: connectKey, args: ["echo", "sim-use-harmonyos-ready"])
    }

    public func describeUI(
        connectKey: String,
        includeOffscreen: Bool = false,
        includeRaw: Bool = true
    ) throws -> DescribeUIResult {
        let data = try fetchRemoteArtifact(
            connectKey: connectKey,
            fileExtension: "json",
            command: { remotePath in
                var arguments = ["uitest", "dumpLayout", "-p", remotePath]
                if includeOffscreen { arguments.append("-i") }
                return arguments
            }
        )
        let root: HarmonyElementNode
        do {
            root = try JSONDecoder().decode(HarmonyElementNode.self, from: data)
        } catch {
            throw HarmonyOSError.malformedOutput("UITest dumpLayout JSON could not be decoded: \(error.localizedDescription)")
        }

        let rendered = HarmonyOutlineRenderer.renderWithActivationPoints(
            root: root,
            options: .init(filterOffscreen: !includeOffscreen)
        )
        let outline = rendered.outline
        let cacheKey = Self.cacheKey(for: connectKey)
        do {
            try OutlineCache.writePayload(
                rendered.cachePayload(udid: cacheKey),
                udid: cacheKey
            )
        } catch {
            FileHandle.standardError.write(Data(
                "warning: failed to write HarmonyOS outline cache for \(connectKey): \(error.localizedDescription)\n".utf8
            ))
        }

        return DescribeUIResult(
            platform: .harmonyos,
            raw: includeRaw ? try JSONValue.decode(from: data) : nil,
            outline: outline.text,
            entries: outline.entries,
            lists: outline.lists,
            screen: outline.screen,
            appLabel: outline.appLabel,
            appPackage: HarmonyOutlineRenderer.appPackage(root: root)
        )
    }

    public func screenshot(connectKey: String) throws -> Data {
        let data = try fetchRemoteArtifact(
            connectKey: connectKey,
            fileExtension: "png",
            command: { remotePath in ["uitest", "screenCap", "-p", remotePath] }
        )
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.starts(with: pngSignature) else {
            throw HarmonyOSError.malformedOutput("UITest screenCap did not produce a PNG file")
        }
        return data
    }

    public func tap(connectKey: String, x: Int, y: Int, duration: Double? = nil) throws {
        if let duration, duration > 0 {
            let milliseconds = try validatedMilliseconds(duration, range: 1...15_000, flag: "duration")
            _ = try hdc.shell(target: connectKey, args: [
                "uinput", "-T", "-d", String(x), String(y),
                "-i", String(milliseconds),
                "-u", String(x), String(y),
            ])
        } else {
            _ = try hdc.shell(target: connectKey, args: [
                "uitest", "uiInput", "click", String(x), String(y),
            ])
        }
    }

    public func swipe(
        connectKey: String,
        startX: Int,
        startY: Int,
        endX: Int,
        endY: Int,
        duration: Double
    ) throws {
        let milliseconds = try validatedMilliseconds(duration, range: 1...15_000, flag: "duration")
        _ = try hdc.shell(target: connectKey, args: [
            "uinput", "-T", "-m",
            String(startX), String(startY), String(endX), String(endY),
            "-k", "0", String(milliseconds),
        ])
    }

    public func touch(
        connectKey: String,
        x: Int,
        y: Int,
        down: Bool,
        up: Bool,
        delay: Double?
    ) throws {
        var args = ["uinput", "-T"]
        if down { args += ["-d", String(x), String(y)] }
        if down, up, let delay, delay > 0 {
            let milliseconds = try validatedMilliseconds(delay, range: 1...15_000, flag: "delay")
            args += ["-i", String(milliseconds)]
        }
        if up { args += ["-u", String(x), String(y)] }
        _ = try hdc.shell(target: connectKey, args: args)
    }

    public func multiTouch(
        connectKey: String,
        startP1: (x: Double, y: Double),
        startP2: (x: Double, y: Double),
        endP1: (x: Double, y: Double),
        endP2: (x: Double, y: Double),
        duration: Double
    ) throws {
        let milliseconds = try validatedMilliseconds(duration, range: 1...15_000, flag: "duration")
        let values = [startP1.x, startP1.y, endP1.x, endP1.y, startP2.x, startP2.y, endP2.x, endP2.y]
            .map { String(Int($0.rounded())) }
        _ = try hdc.shell(target: connectKey, args: ["uinput", "-T", "-m"] + values + [
            "-k", "0", String(milliseconds),
        ])
    }

    public func typeText(connectKey: String, text: String) throws {
        guard !text.isEmpty else { return }
        _ = try hdc.shell(target: connectKey, args: [
            "uitest", "uiInput", "text", Self.remoteShellQuote(text),
        ])
    }

    public func pressButton(connectKey: String, button: String) throws {
        let key: String
        switch button.lowercased() {
        case "home": key = "Home"
        case "back": key = "Back"
        case "lock", "power": key = "Power"
        default:
            throw HarmonyOSError.unsupported(
                "`button \(button)` is not supported on HarmonyOS. Supported: home, back, lock."
            )
        }
        _ = try hdc.shell(target: connectKey, args: ["uitest", "uiInput", "keyEvent", key])
    }

    private func fetchRemoteArtifact(
        connectKey: String,
        fileExtension: String,
        command: (String) -> [String]
    ) throws -> Data {
        let token = UUID().uuidString.lowercased()
        let remotePath = "/data/local/tmp/sim-use-\(token).\(fileExtension)"
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-harmonyos-\(token)", isDirectory: true)
        let localURL = localDirectory.appendingPathComponent("artifact.\(fileExtension)")
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: localDirectory)
            _ = try? hdc.shell(target: connectKey, args: ["rm", "-f", remotePath])
        }

        _ = try hdc.shell(target: connectKey, args: command(remotePath))
        _ = try hdc.receive(target: connectKey, remotePath: remotePath, localPath: localURL.path)
        do {
            return try Data(contentsOf: localURL)
        } catch {
            throw HarmonyOSError.transport("Failed to read hdc-received artifact: \(error.localizedDescription)")
        }
    }

    private func validatedMilliseconds(
        _ seconds: Double,
        range: ClosedRange<Int>,
        flag: String
    ) throws -> Int {
        let milliseconds = Int((seconds * 1000).rounded())
        guard range.contains(milliseconds) else {
            throw HarmonyOSError.unsupported(
                "HarmonyOS --\(flag) must resolve to \(range.lowerBound)...\(range.upperBound) milliseconds."
            )
        }
        return milliseconds
    }

    static func remoteShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
