// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import HarmonyOSBackend
import iOSSimBackend

/// Top-level cross-platform `paste` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command (`IOSSimPasteCommand` for iOS Simulator UDIDs,
/// `AndroidPasteCommand.performPaste` for adb serials).
///
/// `--via-menu` is iOS-only — Android's bridge already bypasses the
/// IME via ACTION_PASTE, so the menu detour is unnecessary there. The
/// Android execute path fails fast on `--via-menu` with an explanatory
/// error rather than approximating it.
struct Paste: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimPasteCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Paste UTF-8 text into an editable field (bypasses IME).",
        discussion: IOSSimPasteCommand.configuration.discussion + "\n\n" + """
        Input methods (mutually exclusive):
          sim-use paste "Hello 日本語" --device UDID
          printf '%s' "$TEXT" | sim-use paste --stdin --device UDID
          sim-use paste --file input.txt --device UDID

        Examples:
          sim-use tap --id chatTextField --device UDID
          sim-use paste "ABC 日本語" --device UDID
          sim-use paste "NEW" --replace --device UDID
          sim-use paste "ABC" --via-menu --target-id chatTextField --device UDID

        Android uses the bridge's ACTION_PASTE; --via-menu is iOS-only.
        Physical iOS devices have no text-input channel yet.
        Always verify the resulting field with `sim-use ui`.
        """
    )

    @Argument(help: "The text to paste. Use quotes for text with spaces or special characters.")
    var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?

    @Flag(name: .customLong("replace"), help: "Select all before pasting to replace the field's current content.")
    var replace: Bool = false

    @Flag(name: .customLong("via-menu"), help: "Long-press an explicit iOS target before native menu Paste. Requires --target-id or --target-x/y; neither mode requires a connected hardware keyboard.")
    var viaMenu: Bool = false

    @Option(name: .customLong("target-id"), help: "For --via-menu: AXUniqueId of the field to long-press. Resolves via the live AX tree.")
    var targetID: String?

    @Option(name: .customLong("target-x"), help: "For --via-menu: X coordinate to long-press.")
    var targetX: Double?

    @Option(name: .customLong("target-y"), help: "For --via-menu: Y coordinate to long-press.")
    var targetY: Double?

    @Option(name: .customLong("coordinate-space"), help: "iOS only, for --target-x/--target-y: 'ui' (the default; visual space as printed by describe-ui, orientation-calibrated) or 'native' (the device's native portrait points, no calibration).")
    var coordinateSpace: CoordinateSpace?

    @Option(name: .customLong("long-press-duration"), help: "Seconds to hold on the field for the edit menu to appear (default: 0.8).")
    var longPressDuration: Double = 0.8

    @Option(name: .customLong("menu-timeout"), help: "Seconds to wait for each edit-menu transition (default: 2.0).")
    var menuTimeout: Double = 2.0

    @OptionGroup var targetPlatform: TargetPlatformOptions

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(platform: targetPlatform.platform, allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { device.resolvedPlatform == .harmonyOS }

    func daemonArguments(from arguments: [String]) throws -> [String] {
        try IOSSimPasteCommand.daemonArguments(from: arguments, useStdin: useStdin, inputFile: inputFile)
    }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimPasteCommand.validateOptions(
            text: text, useStdin: useStdin, inputFile: inputFile,
            viaMenu: viaMenu,
            targetID: targetID,
            targetX: targetX, targetY: targetY,
            coordinateSpace: coordinateSpace,
            longPressDuration: longPressDuration, menuTimeout: menuTimeout
        )
    }

    func execute() async throws -> ExecutionResult {
        switch device.resolvedPlatform {
        case .android:
            return try executeAndroid()
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "paste",
                reason: "the accessibility audit channel exposes no pasteboard or text-input access.",
                alternative: "Text input on physical iOS devices is not available yet. If the step only needs an activation, use `sim-use tap '#<id>' / --label`."
            )
        case .harmonyOS:
            return try await executeHarmonyOS()
        case .iOSSim:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`. Also feeds `clientPreflight`,
    /// which previously copied only the three fields it read — a full
    /// copy means the preflight can never trap if it starts reading
    /// another field.
    func makeIOSSubcommand() -> IOSSimPasteCommand {
        var sub = IOSSimPasteCommand()
        sub.text = text
        sub.useStdin = useStdin
        sub.inputFile = inputFile
        sub.replace = replace
        sub.viaMenu = viaMenu
        sub.targetID = targetID
        sub.targetX = targetX
        sub.targetY = targetY
        sub.coordinateSpace = coordinateSpace
        sub.longPressDuration = longPressDuration
        sub.menuTimeout = menuTimeout
        sub.device = device
        sub.json = json
        return sub
    }

    private func executeAndroid() throws -> ExecutionResult {
        if viaMenu {
            throw CLIError(errorDescription: "--via-menu is iOS-only. On Android the bridge already bypasses the IME via ACTION_PASTE; pass the text directly (with --replace if you want to overwrite the field).")
        }
        let inputText = try IOSSimPasteCommand.resolveInputText(
            text: text, useStdin: useStdin, inputFile: inputFile,
            logger: nil
        )
        guard !inputText.isEmpty else {
            throw CLIError(errorDescription: "Input text is empty; nothing to paste.")
        }
        try AndroidPasteCommand.performPaste(
            udid: device.resolved,
            text: inputText,
            replace: replace
        )
        return ExecutionResult()
    }

    private func executeHarmonyOS() throws -> ExecutionResult {
        if viaMenu {
            throw CLIError(errorDescription: "--via-menu is iOS-only. HarmonyOS uses UITest text injection at the focused field.")
        }
        if replace {
            throw CLIError(errorDescription: "HarmonyOS paste --replace is not available through the stable UITest CLI. Clear the field first, then run paste/type.")
        }
        let inputText = try IOSSimPasteCommand.resolveInputText(
            text: text, useStdin: useStdin, inputFile: inputFile, logger: nil
        )
        guard !inputText.isEmpty else { throw CLIError(errorDescription: "Input text is empty; nothing to paste.") }
        try HarmonyOSTypeCommand.performType(connectKey: device.resolved, text: inputText)
        return ExecutionResult()
    }
}