// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - Error Types

/// Carries a human-readable error message that should reach the user
/// verbatim. Conforms to `LocalizedError` so `error.localizedDescription`
/// returns this message instead of Foundation's NSError bridge default
/// (`"The operation couldn't be completed. (CLIError error 1.)"`).
///
/// `errorDescription` is declared as `String?` (not `String`) so the
/// LocalizedError protocol witness is properly installed — Foundation's
/// bridging machinery only routes `localizedDescription` through the
/// LocalizedError implementation when the witness signature matches the
/// protocol exactly. Internal call sites pass non-optional strings; the
/// implicit Optional promotion keeps every existing callsite unchanged.
/// (LINEIOS-216942: required so daemon-side `DaemonErrorKind.classify`
/// can actually pattern-match the message and detect stale simulators.)
public struct CLIError: LocalizedError {
    public let errorDescription: String?

    public init(errorDescription: String) {
        self.errorDescription = errorDescription
    }
}

/// The target identifier names a physical iPhone or iPad, which the
/// simulator and Android backends cannot serve. Thrown during device
/// resolution so every UDID-scoped verb rejects before dispatch with a
/// pointer to the experimental `ios-device` surface, instead of the
/// shape heuristics misreading the modern 8-16-hex device UDID as an
/// unreachable Android serial.
public struct PhysicalIOSDeviceError: LocalizedError, HintProviding {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public var errorDescription: String? {
        "\(identifier) looks like a physical iOS device; this command only drives iOS Simulators and Android devices/emulators."
    }

    public var hint: String? {
        "Physical iPhones and iPads use the experimental 'sim-use ios-device' surface: 'ios-device devices' lists attached devices, 'ios-device ui' reads the foreground app's accessibility tree, 'ios-device tap' activates an element by label. See 'sim-use ios-device --help'."
    }
}