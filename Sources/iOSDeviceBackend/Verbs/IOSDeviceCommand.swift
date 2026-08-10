// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

public struct IOSDeviceCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ios-device",
        abstract: "Physical iOS device subcommands (experimental).",
        discussion: """
        Drives a connected iPhone or iPad through the accessibility audit
        daemon. Nothing is installed on the device and nothing is signed, but
        the device must be unlocked — a locked screen accepts the connection
        and then reports no elements.

        Element geometry is not available on this channel, so there is no
        coordinate tap, swipe or gesture here; interaction goes through
        accessibility actions instead.
        """,
        subcommands: [Devices.self, UI.self, Tap.self]
    )

    public init() {}

    struct DeviceOptions: ParsableArguments {
        @Option(
            name: [.customLong("device"), .customLong("udid")],
            help: "UDID or ECID of the device. Optional when exactly one is connected."
        )
        var udid: String?
    }

    struct Devices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "devices",
            abstract: "List connected physical iOS devices."
        )

        func run() async throws {
            let devices = try await DeviceSession.connectedDevices()
            if devices.isEmpty {
                print("No physical iOS devices connected.")
                return
            }
            devices.forEach { print("\($0.udid)  \($0.name)  \($0.osVersion)  \($0.state)") }
        }
    }

    struct UI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ui",
            abstract: "Print an outline of the foreground app's accessibility tree."
        )

        @OptionGroup var device: DeviceOptions

        @Option(help: "Number of hierarchy reads to keep in flight.")
        var concurrency: Int = DeviceTreeFetcher.defaultConcurrency

        @Option(help: "Number of DTX connections to spread reads over.")
        var connections: Int = 1

        @Flag(help: "Stop descending at labelled elements. Faster, but misses nested text.")
        var fast = false

        func run() async throws {
            let started = Date()
            let (outline, total) = try await DeviceSession.withClient(udid: device.udid, connections: connections) { client in
                let elements = try await DeviceTreeFetcher(client: client, concurrency: concurrency, stopsAtLabelledNodes: fast).fetchTree()
                return (DeviceOutline(elements: elements), elements.count)
            }
            print(outline.rendered())
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print("\n\(outline.rows.count) elements (\(total) nodes) in \(elapsed) ms")
        }
    }

    struct Tap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tap",
            abstract: "Activate the first element whose label contains the given text.",
            discussion: """
            The element is resolved and activated inside a single connection:
            element handles encode a live pointer, so they cannot be carried
            across processes the way a simulator alias can.
            """
        )

        @OptionGroup var device: DeviceOptions

        @Option(name: .customLong("text"), help: "Substring to match against element labels.")
        var text: String

        func run() async throws {
            let matched = try await DeviceSession.withClient(udid: device.udid) { client -> String? in
                let elements = try await DeviceTreeFetcher(client: client).fetchTree()
                guard let target = elements.first(where: {
                    $0.isAccessibilityElement && $0.summary.localizedCaseInsensitiveContains(text)
                }) else { return nil }
                try await client.perform(.activate, on: target.element)
                return target.summary
            }
            guard let matched else {
                throw ValidationError("no accessibility element matching '\(text)' on screen")
            }
            print("✓ Activated \(matched)")
        }
    }
}
