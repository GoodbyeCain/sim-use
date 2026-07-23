// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Shared `--device` flag declaration plus resolution rule, lifted out
/// of the per-verb structs so all device-scoped commands stay in
/// lockstep on flag name, help text, and auto-resolution semantics.
///
/// Adopt with `@OptionGroup public var device: DeviceOptions` on every
/// command that takes a target simulator / device. Call
/// `try device.resolve()` from the conforming command's
/// `resolveDeferredArguments()`; read `device.resolved` thereafter (it
/// is the empty string until `resolve()` has run).
///
/// `--udid` is accepted as a deprecated alias for `--device`. Passing
/// both flags in one invocation is a fast-fail (a `ValidationError`
/// surfaced through ArgumentParser's normal exit path).
///
/// HarmonyOS and Android identifiers are not disjoint: both hdc and adb
/// may expose an IP:port or opaque alphanumeric serial. The optional
/// `--platform` override is therefore authoritative. Without it, the
/// legacy shape heuristic remains in effect for compatibility.
///
/// Resolution rule mirrors what every cross-platform forwarder did
/// pre-extraction: an explicit Android-shape identifier bypasses the
/// iOS-only `DeviceResolver` (which would otherwise probe `simctl` /
/// daemon footprints) and is kept verbatim. Everything else flows
/// through `DeviceResolver.resolve(explicit:)`.
///
/// Android-only verbs (`sim-use android <verb>`) use
/// `AndroidDeviceOptions` instead — same flag surface but the resolver
/// refuses to auto-pick a booted iOS simulator there, since that would
/// produce a confusing "simulator not booted" failure deep in the
/// wrong backend.
public struct DeviceOptions: ParsableArguments {
    @Option(
        name: .customLong("device"),
        help: "Target device identifier. Top-level commands accept an iOS Simulator UDID, Android adb serial, or HarmonyOS hdc connect-key; platform namespaces use their native identifier. Omit only when the command documents auto-resolution."
    )
    public var device: String?

    @Option(
        name: .customLong("udid"),
        help: ArgumentHelp(
            "Deprecated alias for --device. Still accepted; may be removed in a future release.",
            visibility: .default
        )
    )
    public var udid: String?

    /// Backend override supplied by the top-level `TargetPlatformOptions`.
    /// Platform-specific namespaces leave this nil and therefore cannot
    /// accidentally redirect an `ios` command to another backend.
    public private(set) var platform: Device.Platform?

    /// Resolved device identifier. Populated by `resolve()`; the empty
    /// string until then. Reading this before resolution is a
    /// programmer error in a command's `execute()` body and we accept
    /// the runtime breakage rather than fronting it with an Optional
    /// that would force every call-site to unwrap.
    public var resolved: String = ""

    public init() {}

    /// `allowPhysical` marks the caller as physical-iOS-aware: top-level
    /// cross-platform verbs pass `true` and route (or reject per-verb via
    /// `TargetCapabilityError`) in their platform switch. The `sim-use ios`
    /// namespace keeps the default `false` because it is simulator-only.
    public mutating func resolve(
        platform: Device.Platform? = nil,
        allowPhysical: Bool = false
    ) throws {
        self.platform = platform
        let explicit = try Self.selectExplicit(device: device, udid: udid)
        if let platform {
            switch platform {
            case .ios:
                resolved = try DeviceResolver.resolve(explicit: explicit)
            case .android, .harmonyos:
                let environment = ProcessInfo.processInfo.environment
                let environmentDevice = explicit == nil
                    ? try Self.selectExplicit(
                        device: environment["SIM_USE_DEVICE"],
                        udid: environment["SIM_USE_UDID"]
                    )
                    : nil
                guard let selected = explicit ?? environmentDevice else {
                    throw CLIError(errorDescription: "Pass --device <id> with --platform \(platform.rawValue), or use the platform namespace for automatic single-device resolution.")
                }
                resolved = selected
            }
            return
        }
        if let arg = explicit, PlatformRouter.looksLikeAndroid(arg) {
            resolved = arg
            return
        }
        let candidate = try DeviceResolver.resolve(explicit: explicit)
        // Checked on the resolved value, not just the explicit flag, so a
        // physical UDID arriving via SIM_USE_DEVICE / SIM_USE_UDID is
        // treated identically.
        guard allowPhysical || !PlatformRouter.looksLikePhysicalIOSDevice(candidate) else {
            throw PhysicalIOSDeviceError(identifier: candidate)
        }
        resolved = candidate
    }

    public var resolvedPlatform: Platform {
        PlatformRouter.resolve(udid: resolved, override: platform) ?? .iOSSim
    }

    /// Apply the same `--device` / `--udid` mutual-exclusion rule used
    /// by `DeviceOptions.resolve()` to a pair of raw values. Exposed so
    /// `AndroidDeviceOptions` (and any future variant) reuses the
    /// trim-and-pick-one semantics without re-implementing them.
    ///
    /// Conflicts surface as `CLIError` rather than ArgumentParser's
    /// `ValidationError`. `ValidationError` is only marshalled cleanly
    /// when thrown from inside `validate()`; thrown from
    /// `resolveDeferredArguments()` (where every other deferred
    /// `--device` rule lives) it is wrapped as
    /// `"The operation couldn't be completed. (ArgumentParser.ValidationError error 1.)"`,
    /// hiding the actual diagnostic from both stderr and the
    /// `--json` envelope.
    public static func selectExplicit(
        device: String?,
        udid: String?
    ) throws -> String? {
        let d = device?.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
        let u = udid?.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
        if d != nil && u != nil {
            throw CLIError(errorDescription: "Pass only one of --device / --udid (they are aliases).")
        }
        return d ?? u
    }
}

extension String {
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
