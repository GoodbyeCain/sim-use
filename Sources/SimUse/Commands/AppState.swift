// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import HarmonyOSBackend
import iOSSimBackend

/// `sim-use app-state` — a lightweight, cross-platform read of which apps
/// are running on the device (no accessibility-tree fetch), plus the
/// `--reset` baseline control for crash detection (issue #81).
///
/// Routes through the per-UDID daemon like the interaction verbs so that
/// `--reset` re-baselines the *daemon's* `ProcessLivenessTracker` and
/// clears any pending crash signal. `managesLivenessState` keeps dispatch
/// from auto-evaluating the tracker for this command (it owns it).
struct AppState: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-state",
        abstract: AppStateHelp.abstract
    )

    @OptionGroup var targetPlatform: TargetPlatformOptions

    @OptionGroup var device: DeviceOptions

    @Option(
        name: .customLong("bundle-id"),
        help: ArgumentHelp(
            AppStateHelp.bundleId,
            valueName: "id"
        )
    )
    var bundleId: String?

    @Flag(
        name: .customLong("reset"),
        help: ArgumentHelp(AppStateHelp.reset)
    )
    var reset: Bool = false

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { device.resolvedPlatform == .harmonyOS }

    var managesLivenessState: Bool { true }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(platform: targetPlatform.platform, allowPhysical: true)
    }

    // MARK: - Result

    typealias AppProcess = AppStateReport.AppProcess
    typealias AppStateQuery = AppStateReport.AppStateQuery
    typealias ExecutionResult = AppStateReport.ExecutionResult

    func execute() async throws -> ExecutionResult {
        let udid = device.resolved
        switch device.resolvedPlatform {
        case .android:
            return try AndroidAppStateCommand.performAppState(
                serial: udid, bundleId: bundleId, reset: reset
            )
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "app-state",
                reason: "there is no process-list channel for physical devices — the accessibility audit channel reads UI trees only, and crash detection is daemon state physical targets don't participate in yet.",
                alternative: "Read the foreground app with `sim-use ui` instead; its outline header and content reflect what is currently on screen."
            )
        case .harmonyOS:
            throw CLIError(errorDescription: "HarmonyOS app-state is not available through the stable hdc process-list contract yet.")
        case .iOSSim:
            break
        }
        let probed = BundleIdentifierResolver.appSnapshot(udid: udid)

        // A nil probe means the process list could not be read (device
        // busy, mid-boot, or disconnected). Surface that as an error
        // rather than reporting a misleading empty "not_running" result.
        guard let snapshot = probed else {
            throw CLIError(errorDescription:
                "Could not read the running-process list from \(udid). " +
                "The device may be busy, mid-boot, or disconnected — retry in a moment.")
        }

        if reset {
            // In the daemon this re-baselines the live tracker; standalone
            // (no daemon) resets a per-invocation instance and is a no-op
            // across commands — documented.
            DaemonDispatch.processTracker.reset(to: snapshot, now: Date())
        }

        return Self.buildResult(
            platform: "ios",
            snapshot: snapshot,
            bundleId: bundleId,
            didReset: reset
        )
    }

    /// Pure snapshot → result mapping. Exposed for tests.
    static func buildResult(
        platform: String,
        snapshot: AppSnapshot,
        bundleId: String?,
        didReset: Bool
    ) -> ExecutionResult {
        AppStateReport.buildResult(
            platform: platform, snapshot: snapshot, bundleId: bundleId, didReset: didReset
        )
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        AppStateReport.format(result)
    }
}
