// SPDX-License-Identifier: Apache-2.0
import FBControlCore
import FBDeviceControl
import Foundation

public enum DeviceSessionError: Error, LocalizedError, CustomStringConvertible {
    case deviceNotFound(udid: String, available: [String])
    case serviceUnavailable(underlying: Error)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case let .deviceNotFound(udid, available):
            let known = available.isEmpty ? "none connected" : available.joined(separator: ", ")
            return "no physical iOS device with UDID \(udid) (connected: \(known))"
        case let .serviceUnavailable(underlying):
            return "could not open the accessibility service on the device: \(underlying.localizedDescription)"
        }
    }
}

/// Opens the accessibility audit daemon on a physical device and scopes it to
/// one piece of work.
///
/// Nothing is installed on the device and nothing is signed: the service is
/// reached over plain usbmux lockdown. The device does need to be unlocked —
/// a locked screen answers connections but reports no elements.
public enum DeviceSession {
    /// The `.DVTSecureSocketProxy` variant terminates TLS on the lockdown side,
    /// so the DTX stream underneath is plaintext. Without it the daemon expects
    /// a stripped-SSL channel and the first frame decodes as garbage.
    /// There is no `.DVTSecureSocketProxy` variant of this service — lockdown
    /// rejects it with "the service is invalid" — so TLS is stripped on our
    /// side instead, in `DTXConnection`.
    static let serviceName = "com.apple.accessibility.axAuditDaemon.remoteserver"

    public struct DeviceSummary: Sendable {
        public let udid: String
        public let name: String
        public let osVersion: String
        public let state: String
    }

    public static func connectedDevices(logger: FBControlCoreLogger? = nil) async throws -> [DeviceSummary] {
        let set = try await MainActor.run { try deviceSet(logger: logger) }
        return await settled(set).map {
            DeviceSummary(
                udid: $0.identity,
                name: $0.name,
                osVersion: $0.osVersion.name.rawValue,
                state: FBiOSTargetStateStringFromState($0.state).rawValue
            )
        }
    }

    public static func withClient<Result>(
        udid: String?,
        connections poolSize: Int = 1,
        logger: FBControlCoreLogger? = nil,
        body: (AXAuditClient) async throws -> Result
    ) async throws -> Result {
        let set = try await MainActor.run { try deviceSet(logger: logger) }
        let device = try resolve(udid, among: await settled(set))

        do {
            return try await withConnections(to: device, count: max(1, poolSize)) { dtx in
                let client = AXAuditClient(transport: PooledTransport(connections: dtx))
                try await client.prepare()
                // Not `defer`: the teardown has to complete while the
                // connections are still open, and a detached task would race
                // them shut.
                do {
                    let result = try await body(client)
                    await client.finish()
                    return result
                } catch {
                    await client.finish()
                    throw error
                }
            }
        } catch let error as DeviceSessionError {
            throw error
        } catch {
            throw DeviceSessionError.serviceUnavailable(underlying: error)
        }
    }

    /// Opens `count` service connections and tears them all down afterwards.
    /// Nesting the contexts keeps each one scoped without hand-rolled cleanup.
    private static func withConnections<Result>(
        to device: FBDevice,
        count: Int,
        body: ([DTXConnection]) async throws -> Result
    ) async throws -> Result {
        var opened: [DTXConnection] = []

        func open(_ remaining: Int) async throws -> Result {
            guard remaining > 0 else { return try await body(opened) }
            return try await withFBFutureContext(device.startService(serviceName)) { connection in
                let dtx = try DTXConnection(connection: connection)
                defer { dtx.close() }
                try dtx.handshake()
                opened.append(dtx)
                return try await open(remaining - 1)
            }
        }
        return try await open(count)
    }

    /// AMDevice attachment is delivered through CFRunLoop sources on the thread
    /// that subscribed, and `FBDeviceSet` subscribes on the main queue. A CLI
    /// that never spins the main run loop therefore only ever sees the
    /// restorable-device half of a connected phone, and `startService:` then
    /// fails with "not AMDevice backed". Pumping the loop here is what lets the
    /// attachment land.
    @MainActor
    private static func attachedDevices(_ set: FBDeviceSet, timeout: TimeInterval = 5) -> [FBDevice] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let attached = set.allDevices.filter { $0.amDevice != nil }
            if !attached.isEmpty { return attached }
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return set.allDevices
    }

    /// AMDevice does not publish the lockdown UDID until a session is opened,
    /// so a connected device is identified by its ECID until then. Accept
    /// either, and default to the only device when there is just one.
    private static func resolve(_ identifier: String?, among devices: [FBDevice]) throws -> FBDevice {
        guard let identifier else {
            guard devices.count == 1, let only = devices.first else {
                throw DeviceSessionError.deviceNotFound(
                    udid: "<unspecified>",
                    available: devices.map { $0.identity }
                )
            }
            return only
        }
        guard let device = devices.first(where: { $0.udid == identifier || $0.uniqueIdentifier == identifier }) else {
            throw DeviceSessionError.deviceNotFound(udid: identifier, available: devices.map { $0.identity })
        }
        return device
    }

    /// `FBDeviceSet` discovers devices through AMDevice notifications delivered
    /// on the main queue, so a set read immediately after construction is
    /// always empty. Yield until the first device lands.
    private static func settled(_ set: FBDeviceSet) async -> [FBDevice] {
        await MainActor.run { attachedDevices(set) }
    }

    @MainActor
    private static func deviceSet(logger: FBControlCoreLogger?) throws -> FBDeviceSet {
        try FBDeviceSet(
            logger: logger ?? FBControlCoreGlobalConfiguration.defaultLogger,
            delegate: nil,
            ecidFilter: nil
        )
    }
}

extension FBDevice {
    var identity: String { udid != "unknown" ? udid : uniqueIdentifier }
}
