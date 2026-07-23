// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import HarmonyOSBackend
import iOSSimBackend

/// Top-level cross-platform `long-press` verb. Mirrors `Tap`'s entire
/// flag surface (selectors, frame filter, delays, wait/poll, UDID,
/// JSON) — the only difference is `--duration` defaults to 0.8s so
/// `sim-use long-press @5` is a one-liner that crosses the OS
/// long-press threshold on both platforms:
///   • iOS: HID `touchDownAt → sleep → touchUpAt` (split submission so
///     UILongPressGestureRecognizer observes a real hold).
///   • Android: `dispatchGesture` with a single `start == end` stroke
///     of the requested duration, dispatched through bridge `/swipe`.
///
/// Implementation is intentionally a thin shell: routing and per-
/// platform forwarding are copies of `Tap.executeIOSSim` /
/// `Tap.executeAndroid` with `duration` carried through. We do not
/// reconstruct a `Tap` instance because `Tap` is parsed by
/// ArgumentParser and has no callable empty initialiser outside that
/// pathway.
struct LongPress: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "long-press",
        abstract: LongPressHelp.abstract,
        discussion: LongPressHelp.discussion
    )

    @Argument(help: ArgumentHelp(
        LongPressHelp.alias,
        valueName: "alias"
    ))
    var alias: String?

    @OptionGroup var targeting: TapTargetingOptions

    @Option(
        name: .customLong("duration"),
        help: ArgumentHelp(
            LongPressHelp.duration
        )
    )
    var duration: Double = 0.8

    @OptionGroup var timing: TapTimingOptions

    @OptionGroup var multiTouch: MultiTouchOptions

    @OptionGroup var targetPlatform: TargetPlatformOptions

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(platform: targetPlatform.platform, allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { device.resolvedPlatform == .harmonyOS }

    typealias ExecutionResult = IOSSimTapCommand.ExecutionResult

    /// Same shared group validators as `Tap` / `IOSSimTapCommand` —
    /// same selector / coordinate / delay constraints apply, and the
    /// duration default (0.8) is in the [0, 10] range so the validator
    /// accepts it. ArgumentParser does not auto-validate nested option
    /// groups, so these explicit calls are load-bearing
    /// (`TapValidationParityTests` pins that every surface makes them).
    func validate() throws {
        try targeting.validate(alias: alias)
        try timing.validate()
        try TapTimingOptions.validateDuration(duration)
        try multiTouch.validate()
    }

    func execute() async throws -> ExecutionResult {
        switch device.resolvedPlatform {
        case .android:
            return try executeAndroid()
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "long-press",
                reason: "the audit channel's only exposed action is Activate — there is no coordinate input or press-duration control.",
                alternative: "Use `sim-use tap '#<id>' / --label` for a plain activation; long-press gestures are not available on physical iOS devices."
            )
        case .harmonyOS:
            return try await executeHarmonyOS()
        case .iOSSim:
            return try await executeIOSSim()
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        // x/y are always present here — long-press rejects physical iOS
        // (the only coordinate-less producer) in its platform switch.
        guard let x = result.x, let y = result.y else {
            return .line(result.summaryLine)
        }
        return .line("✓ Long-press at (\(x), \(y)) completed successfully")
    }

    /// iOS path: hand off to the tap executor with `--duration` carried
    /// through — it already splits the HID event into down → sleep → up
    /// when duration > 0, which is exactly the long-press recipe. The
    /// parsed groups are handed over as values, so no backend command
    /// instance is hand-built and there is no per-field copy to
    /// forget (#42).
    private func executeIOSSim() async throws -> ExecutionResult {
        try await IOSSimTapCommand.performTap(
            alias: alias,
            targeting: targeting,
            timing: timing,
            duration: duration,
            multiTouch: multiTouch,
            device: device,
            json: json
        )
    }

    /// Android path: same selector resolution as `tap`, then a
    /// `BridgeClient.swipe(start=end, durationMs)` via the duration-
    /// aware `AndroidTapCommand.performTap` entry point. One stroke
    /// with `start == end` is the Android-native long-press shape
    /// (`AccessibilityService.dispatchGesture` cannot hold a stroke
    /// across calls).
    private func executeAndroid() throws -> ExecutionResult {
        let result = try AndroidLongPressCommand.performLongPress(
            serial: device.resolved, alias: alias, targeting: targeting,
            duration: duration, multiTouch: multiTouch
        )
        return ExecutionResult(x: result.x, y: result.y)
    }

    private func executeHarmonyOS() async throws -> ExecutionResult {
        guard multiTouch.fingers == 1 else {
            throw CLIError(errorDescription: "HarmonyOS long-press currently supports one finger; use `multi-touch` for an explicit two-finger hold.")
        }
        let frameFilter = targeting.frameSpecs.isEmpty
            ? nil
            : try? SelectorFrameFilter(specs: targeting.frameSpecs)
        let selector = HarmonySelector(
            id: targeting.elementID,
            label: targeting.elementLabel,
            labelContains: targeting.labelContains,
            labelRegex: targeting.labelRegex,
            value: targeting.elementValue,
            elementType: targeting.elementType,
            frame: frameFilter
        )
        let explicit = try TapCoordinateResolver.resolve(
            x: targeting.pointX, y: targeting.pointY, point: targeting.point
        )
        let result = try await HarmonyOSTapCommand.performTap(
            connectKey: device.resolved,
            alias: alias,
            x: explicit.map { Int($0.x.rounded()) },
            y: explicit.map { Int($0.y.rounded()) },
            selector: selector,
            duration: duration,
            preDelay: timing.preDelay,
            postDelay: timing.postDelay,
            waitTimeout: timing.waitTimeout,
            pollInterval: timing.pollInterval
        )
        return ExecutionResult(x: Double(result.x), y: Double(result.y))
    }
}
