// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Cross-platform identifier for one connected device sim-use can target —
/// an iOS Simulator runtime from `simctl list devices`, an Android
/// device / emulator from `adb devices`, a physical iPhone / iPad from
/// `FBDeviceControl` discovery, or a HarmonyOS target from
/// `hdc list targets -v`. The platforms originally shipped with separate
/// listing commands and ad-hoc output shapes; `Device` is the unified row
/// emitted by the top-level `sim-use devices` verb.
///
/// `platform` answers "which OS", `kind` answers "which carrier" —
/// deliberately orthogonal axes because capabilities follow the kind.
///
/// `state` is intentionally a free-form string: iOS reports
/// `Booted` / `Shutdown` / `Shutting Down` / `Booting` / `Creating`, and
/// Android reports `device` / `offline` / `unauthorized`, and HarmonyOS
/// reports hdc connection states such as `Connected` / `Offline`. Callers that
/// just want "can I act on this now?" should use `isUsable`, which
/// applies the per-platform rule.
public struct Device: Codable, Equatable, Hashable, Sendable {
    /// Custom keys for the device-id wire migration. `deviceId` is the
    /// canonical cross-platform key and the only one emitted; `udid`
    /// is the historic name, still accepted on decode as a deprecated
    /// fallback (to be removed in a future release).
    private enum CodingKeys: String, CodingKey {
        case udid
        case deviceId
        case name
        case platform
        case kind
        case state
        case runtime
    }

    public enum Platform: String, Codable, Sendable, CaseIterable, ExpressibleByArgument {
        case ios
        case android
        case harmonyos

        public init?(argument: String) {
            self.init(rawValue: argument.lowercased())
        }
    }

    /// What carries the OS: a Simulator runtime, an Android emulator, or
    /// real hardware. Orthogonal to `platform`.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case simulator
        case emulator
        case physical
    }

    /// Platform-state strings as the underlying tools emit them.
    /// Extracted as named constants so a future renaming of an iOS
    /// state ("Booted" → something else in a future simctl) or an
    /// Android / HarmonyOS one is a single-source change instead of grepping
    /// for the literal across Device, SimctlDeviceLister, Devices,
    /// DeviceModelTests.
    public enum State {
        public static let iosBooted = "Booted"
        public static let iosShutdown = "Shutdown"
        public static let androidOnline = "device"
        public static let androidOffline = "offline"
        public static let androidUnauthorized = "unauthorized"
        public static let harmonyOSConnected = "Connected"
        public static let harmonyOSReady = "Ready"
    }

    public let udid: String
    public let name: String
    public let platform: Platform
    public let kind: Kind
    public let state: String
    /// Human-readable runtime label. iOS: the simctl runtime
    /// (`iOS 18.6`, `watchOS 26.1`) or the physical device's OS
    /// (`iOS 26.6`); Android / HarmonyOS use a platform label when an OS
    /// version is not fetched to keep `devices` cheap.
    public let runtime: String?

    public init(
        udid: String,
        name: String,
        platform: Platform,
        kind: Kind,
        state: String,
        runtime: String?
    ) {
        self.udid = udid
        self.name = name
        self.platform = platform
        self.kind = kind
        self.state = state
        self.runtime = runtime
    }

    /// Compatibility initializer for callers that predate the `kind` axis.
    /// iOS rows historically represented simulators; non-iOS rows default to
    /// physical hardware until a lister can provide a more precise carrier.
    public init(
        udid: String,
        name: String,
        platform: Platform,
        state: String,
        runtime: String?
    ) {
        self.init(
            udid: udid,
            name: name,
            platform: platform,
            kind: platform == .ios ? .simulator : .physical,
            state: state,
            runtime: runtime
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        let udid = try c.decodeIfPresent(String.self, forKey: .udid)
        guard let resolved = deviceId ?? udid else {
            throw DecodingError.keyNotFound(
                CodingKeys.deviceId,
                .init(codingPath: decoder.codingPath, debugDescription: "Device payload missing both `deviceId` and `udid`.")
            )
        }
        self.udid = resolved
        self.name = try c.decode(String.self, forKey: .name)
        self.platform = try c.decode(Platform.self, forKey: .platform)
        self.state = try c.decode(String.self, forKey: .state)
        self.runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        // Payloads from before the `kind` field (older daemons, cached
        // JSON) carry enough to infer it: pre-kind iOS listings only ever
        // contained simulators, and the Android emulator serial prefix is
        // the same signal `adb` consumers have always used.
        if let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) {
            self.kind = kind
        } else {
            switch platform {
            case .ios:     kind = .simulator
            case .android: kind = resolved.hasPrefix("emulator-") ? .emulator : .physical
            case .harmonyos: kind = .physical
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(udid, forKey: .deviceId)
        try c.encode(name, forKey: .name)
        try c.encode(platform, forKey: .platform)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(runtime, forKey: .runtime)
    }

    /// Whether sim-use can talk to this device right now. iOS: only
    /// `Booted` sims accept HID + a11y. Android: `device` is the online
    /// state. HarmonyOS: hdc reports `Connected` or `Ready` for usable
    /// USB, TCP, physical-device, and emulator targets.
    public var isUsable: Bool {
        switch platform {
        case .ios:     return state == State.iosBooted
        case .android: return state == State.androidOnline
        case .harmonyos:
            return state.caseInsensitiveCompare(State.harmonyOSConnected) == .orderedSame
                || state.caseInsensitiveCompare(State.harmonyOSReady) == .orderedSame
        }
    }
}
