// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public struct HarmonyOSCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "harmonyos",
        abstract: "HarmonyOS emulator and physical-device commands via hdc / UITest.",
        subcommands: [
            HarmonyOSDevicesCommand.self,
            HarmonyOSPingCommand.self,
            HarmonyOSDescribeUICommand.self,
            HarmonyOSTapCommand.self,
            HarmonyOSSwipeCommand.self,
            HarmonyOSTypeCommand.self,
            HarmonyOSButtonCommand.self,
            HarmonyOSTouchCommand.self,
            HarmonyOSMultiTouchCommand.self,
            HarmonyOSScreenshotCommand.self,
        ]
    )

    public init() {}
}

public struct HarmonyDeviceOptions: ParsableArguments {
    @Option(name: .customLong("device"), help: "HarmonyOS hdc connect-key. Defaults to the only connected hdc target.")
    public var device: String?

    @Option(
        name: .customLong("udid"),
        help: ArgumentHelp("Deprecated alias for --device.", visibility: .default)
    )
    public var udid: String?

    public var resolved = ""

    public init() {}

    public mutating func resolve(controller: HarmonyDeviceController = HarmonyDeviceController()) throws {
        if let explicit = try DeviceOptions.selectExplicit(device: device, udid: udid) {
            resolved = explicit
            return
        }

        let env = ProcessInfo.processInfo.environment
        if let explicit = try DeviceOptions.selectExplicit(
            device: env["SIM_USE_DEVICE"],
            udid: env["SIM_USE_UDID"]
        ) {
            resolved = explicit
            return
        }

        let online = try controller.listTargets().filter(\.isOnline)
        if online.count == 1 {
            resolved = online[0].connectKey
            return
        }
        if online.isEmpty {
            throw HarmonyOSError.targetNotFound("<automatic>")
        }
        let keys = online.map(\.connectKey).joined(separator: ", ")
        throw HarmonyOSError.unsupported(
            "Multiple HarmonyOS targets are connected (\(keys)). Pass --device <connect-key>."
        )
    }
}

public struct HarmonyOSDevicesCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List HarmonyOS emulators and physical devices visible to hdc."
    )

    @Flag(name: .customLong("all"), help: "Include offline and unauthorized hdc targets.")
    public var includeAll = false
    @Flag(name: .customLong("json")) public var jsonOutput = false

    public init() {}

    public struct ExecutionResult: Codable { public let devices: [Device] }

    public func execute() async throws -> ExecutionResult {
        var devices = try HarmonyDeviceController().listUnifiedDevices()
        if !includeAll { devices = devices.filter(\.isUsable) }
        return ExecutionResult(devices: devices)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard !result.devices.isEmpty else { return .line("No connected HarmonyOS targets found.") }
        return .lines(result.devices.map { "\($0.udid)\t\($0.state)\t\($0.name)" })
    }
}

public struct HarmonyOSPingCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "ping", abstract: "Verify hdc shell access to a HarmonyOS target.")
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public let deviceId: String; public let ready: Bool }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        try HarmonyDeviceController().ping(connectKey: device.resolved)
        return ExecutionResult(deviceId: device.resolved, ready: true)
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ HarmonyOS target \(result.deviceId) is ready") }
}

public struct HarmonyOSDescribeUICommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Describe the HarmonyOS UI via UITest dumpLayout.",
        aliases: ["ui"]
    )
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("include-offscreen")) public var includeOffscreen = false
    @Flag(name: .customLong("json")) public var jsonOutput = false
    @OptionGroup public var output: DescribeUIOutputOptions
    public init() {}
    public typealias ExecutionResult = DescribeUIResult
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func validate() throws { try output.validate(jsonOutput: jsonOutput) }
    public func execute() async throws -> ExecutionResult {
        let result = try Self.performDescribeUI(
            connectKey: device.resolved,
            includeOffscreen: includeOffscreen,
            includeRaw: jsonOutput && !output.compact
        )
        return output.compact ? result.compacted() : result
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .raw(result.outline) }
    public static func performDescribeUI(
        connectKey: String,
        includeOffscreen: Bool,
        includeRaw: Bool,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) throws -> DescribeUIResult {
        try controller.describeUI(
            connectKey: connectKey,
            includeOffscreen: includeOffscreen,
            includeRaw: includeRaw
        )
    }
}

public struct HarmonyOSTapCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "tap", abstract: "Tap a HarmonyOS element by alias, selector, or coordinate.")
    @OptionGroup public var device: HarmonyDeviceOptions
    @Argument public var alias: String?
    @OptionGroup public var targeting: TapTargetingOptions
    @Option(
        name: .customLong("duration"),
        help: "How long to hold the touch in seconds. Omitted or zero uses the reliable 0.05s HarmonyOS tap interval."
    ) public var duration: Double?
    @OptionGroup public var timing: TapTimingOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false

    public init() {}
    public struct ExecutionResult: Codable { public let x: Double; public let y: Double }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }

    public func validate() throws {
        try targeting.validate(alias: alias)
        try timing.validate()
        try TapTimingOptions.validateDuration(duration)
    }

    public func execute() async throws -> ExecutionResult {
        let explicit = try TapCoordinateResolver.resolve(
            x: targeting.pointX,
            y: targeting.pointY,
            point: targeting.point
        )
        let result = try await Self.performTap(
            connectKey: device.resolved,
            alias: alias,
            x: explicit.map { Int($0.x.rounded()) },
            y: explicit.map { Int($0.y.rounded()) },
            selector: selector(),
            duration: duration,
            preDelay: timing.preDelay,
            postDelay: timing.postDelay,
            waitTimeout: timing.waitTimeout,
            pollInterval: timing.pollInterval
        )
        return ExecutionResult(x: Double(result.x), y: Double(result.y))
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Tap at (\(Int(result.x)), \(Int(result.y))) completed successfully")
    }

    public static func performTap(
        connectKey: String,
        alias: String?,
        x: Int?,
        y: Int?,
        selector: HarmonySelector,
        duration: Double? = nil,
        preDelay: Double? = nil,
        postDelay: Double? = nil,
        waitTimeout: Double = 0,
        pollInterval: Double = 0.25,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) async throws -> (x: Int, y: Int, description: String) {
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        let deadline = Date().addingTimeInterval(waitTimeout)
        let target: HarmonyTargetResolver.Target
        while true {
            do {
                target = try HarmonyTargetResolver.resolve(
                    connectKey: connectKey,
                    alias: alias,
                    x: x,
                    y: y,
                    selector: selector,
                    controller: controller
                )
                break
            } catch let error as HarmonyTargetResolutionError {
                guard waitTimeout > 0,
                      alias == nil,
                      x == nil,
                      y == nil,
                      !selector.isEmpty,
                      Date() < deadline,
                      error.isRetryable else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        try controller.tap(connectKey: connectKey, x: target.x, y: target.y, duration: duration)
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return (target.x, target.y, target.description)
    }

    private func selector() -> HarmonySelector {
        HarmonySelector(
            id: targeting.elementID,
            label: targeting.elementLabel,
            labelContains: targeting.labelContains,
            labelRegex: targeting.labelRegex,
            value: targeting.elementValue,
            elementType: targeting.elementType,
            frame: targeting.frameSpecs.isEmpty
                ? nil
                : try? SelectorFrameFilter(specs: targeting.frameSpecs)
        )
    }
}

public struct HarmonyOSSwipeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "swipe", abstract: "Swipe on a HarmonyOS target.")
    @OptionGroup public var coordinates: SwipeCoordinateOptions
    @Option(name: .customLong("duration")) public var duration = 0.3
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public let coordinates: SwipeCoordinates }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func validate() throws {
        _ = try coordinates.resolve()
        guard duration > 0, duration <= 10 else { throw ValidationError("--duration must be in (0, 10].") }
    }
    public func execute() async throws -> ExecutionResult {
        let resolved = try coordinates.resolve()
        try Self.performSwipe(connectKey: device.resolved, coordinates: resolved, duration: duration)
        return ExecutionResult(coordinates: resolved)
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ Swipe \(result.coordinates.displaySummary) completed successfully") }
    public static func performSwipe(
        connectKey: String,
        coordinates: SwipeCoordinates,
        duration: Double,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) throws {
        try controller.swipe(
            connectKey: connectKey,
            startX: coordinates.roundedStartX,
            startY: coordinates.roundedStartY,
            endX: coordinates.roundedEndX,
            endY: coordinates.roundedEndY,
            duration: duration
        )
    }
}

public struct HarmonyOSTypeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text at the focused HarmonyOS field via UITest.")
    @Argument public var text: String?
    @Flag(name: .customLong("stdin")) public var useStdin = false
    @Option(name: .customLong("file")) public var inputFile: String?
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public init() {} }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func validate() throws {
        let count = (text == nil ? 0 : 1) + (useStdin ? 1 : 0) + (inputFile == nil ? 0 : 1)
        guard count == 1 else { throw ValidationError("Provide exactly one of positional text, --stdin, or --file.") }
    }
    public func execute() async throws -> ExecutionResult {
        try Self.performType(connectKey: device.resolved, text: try resolvedText())
        return ExecutionResult()
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }
    public static func performType(
        connectKey: String,
        text: String,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) throws {
        try controller.typeText(connectKey: connectKey, text: text)
    }
    private func resolvedText() throws -> String {
        if let text { return text }
        if useStdin { return String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" }
        if let inputFile { return try String(contentsOfFile: inputFile, encoding: .utf8) }
        return ""
    }
}

public struct HarmonyOSButtonCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "button", abstract: "Press home, back, or lock on HarmonyOS.")
    @Argument public var button: String
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public init() {} }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        try Self.performPress(connectKey: device.resolved, button: button)
        return ExecutionResult()
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ \(button) press completed successfully") }
    public static func performPress(
        connectKey: String,
        button: String,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) throws {
        try controller.pressButton(connectKey: connectKey, button: button)
    }
}

public struct HarmonyOSTouchCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "touch", abstract: "Inject HarmonyOS touch down/up events via uinput.")
    @Option(name: [.customShort("x"), .customLong("x")]) public var x: Double
    @Option(name: [.customShort("y"), .customLong("y")]) public var y: Double
    @Flag(name: .customLong("down")) public var down = false
    @Flag(name: .customLong("up")) public var up = false
    @Option(name: .customLong("delay")) public var delay: Double?
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public init() {} }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func validate() throws {
        guard down || up else { throw ValidationError("Specify --down, --up, or both.") }
        if delay != nil, !(down && up) { throw ValidationError("--delay requires both --down and --up.") }
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= 100_000, y <= 100_000 else {
            throw ValidationError("Coordinates must be finite values between 0 and 100000.")
        }
        if let delay, !(0...10).contains(delay) {
            throw ValidationError("--delay must be between 0 and 10 seconds.")
        }
    }
    public func execute() async throws -> ExecutionResult {
        try HarmonyDeviceController().touch(
            connectKey: device.resolved,
            x: Int(x.rounded()), y: Int(y.rounded()),
            down: down, up: up, delay: delay
        )
        return ExecutionResult()
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }
}

public struct HarmonyOSMultiTouchCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "multi-touch", abstract: "Inject a two-finger linear HarmonyOS gesture via uinput.")
    @Option(name: .customLong("x1")) public var x1: Double
    @Option(name: .customLong("y1")) public var y1: Double
    @Option(name: .customLong("x2")) public var x2: Double
    @Option(name: .customLong("y2")) public var y2: Double
    @Option(name: .customLong("x1-end")) public var x1End: Double
    @Option(name: .customLong("y1-end")) public var y1End: Double
    @Option(name: .customLong("x2-end")) public var x2End: Double
    @Option(name: .customLong("y2-end")) public var y2End: Double
    @Option(name: .customLong("duration")) public var duration = 0.5
    @OptionGroup public var device: HarmonyDeviceOptions
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public init() {} }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func validate() throws {
        let coordinates = [x1, y1, x2, y2, x1End, y1End, x2End, y2End]
        guard coordinates.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }) else {
            throw ValidationError("Coordinates must be finite values between 0 and 100000.")
        }
        guard duration > 0, duration <= 10 else {
            throw ValidationError("--duration must be in (0, 10].")
        }
    }
    public func execute() async throws -> ExecutionResult {
        try Self.performMultiTouch(
            connectKey: device.resolved,
            startP1: (x1, y1), startP2: (x2, y2),
            endP1: (x1End, y1End), endP2: (x2End, y2End),
            duration: duration
        )
        return ExecutionResult()
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ HarmonyOS multi-touch completed") }
    public static func performMultiTouch(
        connectKey: String,
        startP1: (Double, Double),
        startP2: (Double, Double),
        endP1: (Double, Double),
        endP2: (Double, Double),
        duration: Double,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) throws {
        try controller.multiTouch(
            connectKey: connectKey,
            startP1: (startP1.0, startP1.1), startP2: (startP2.0, startP2.1),
            endP1: (endP1.0, endP1.1), endP2: (endP2.0, endP2.1),
            duration: duration
        )
    }
}

public struct HarmonyOSScreenshotCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "screenshot", abstract: "Capture a HarmonyOS screenshot via UITest.")
    @OptionGroup public var device: HarmonyDeviceOptions
    @Option public var output: String?
    @Flag(name: .customLong("json")) public var jsonOutput = false
    public init() {}
    public struct ExecutionResult: Codable { public let path: String }
    public var daemonBypass: Bool { true }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        let path = try Self.performScreenshot(connectKey: device.resolved, output: output)
        return ExecutionResult(path: path)
    }
    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(stdout: result.path + "\n", stderr: "Screenshot saved to \(result.path)\n")
    }
    public static func performScreenshot(
        connectKey: String,
        output: String?,
        controller: HarmonyDeviceController = HarmonyDeviceController()
    ) throws -> String {
        let data = try controller.screenshot(connectKey: connectKey)
        let destination = resolveOutput(connectKey: connectKey, output: output)
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }
    private static func resolveOutput(connectKey: String, output: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "HarmonyOS Screenshot - \(connectKey) - \(formatter.string(from: Date())).png"
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FileManager.default.currentDirectoryPath + "/" + name
        }
        let expanded = (output as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var isDirectory: ObjCBool = false
        if (FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory) && isDirectory.boolValue)
            || absolute.hasSuffix("/") {
            let directory = absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
            return directory + "/" + name
        }
        return absolute
    }
}
