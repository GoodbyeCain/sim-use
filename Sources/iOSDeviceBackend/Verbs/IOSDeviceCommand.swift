// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

enum IOSDeviceCommandError: Error, LocalizedError, CustomStringConvertible {
    case noMatchingElement(selector: String, available: [String])
    case multipleMatches(selector: String, matches: [String])
    case missingSelector

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .noMatchingElement(selector, available):
            let candidates = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "no accessibility element matched \(selector) on screen (available: \(candidates)); run 'sim-use ios-device ui' and choose a visible label"
        case let .multipleMatches(selector, matches):
            return "\(selector) matched multiple accessibility elements (\(matches.joined(separator: ", "))); use --label for an exact match or add --element-type"
        case .missingSelector:
            return "tap requires exactly one of --label or --label-contains"
        }
    }
}

struct DeviceTapTargetResolver {
    static func resolve(
        _ elements: [DeviceElement],
        label: String?,
        labelContains: String?,
        elementType: String?
    ) throws -> DeviceElement {
        let selectorDescription: String
        let matchesLabel: (String) -> Bool

        if let label {
            selectorDescription = "--label '\(label)'"
            matchesLabel = { $0.localizedCaseInsensitiveCompare(label) == .orderedSame }
        } else if let labelContains {
            selectorDescription = "--label-contains '\(labelContains)'"
            matchesLabel = { $0.localizedCaseInsensitiveContains(labelContains) }
        } else {
            throw IOSDeviceCommandError.missingSelector
        }

        let accessible = elements.filter(\.isAccessibilityElement)
        let matches = accessible.filter { element in
            matchesLabel(DeviceOutline.label(from: element.summary, role: element.role))
                && elementType.map {
                    element.role.localizedCaseInsensitiveCompare($0) == .orderedSame
                } != false
        }

        guard !matches.isEmpty else {
            throw IOSDeviceCommandError.noMatchingElement(
                selector: selectorDescription,
                available: Array(accessible.prefix(8).map(describe))
            )
        }
        if matches.count == 1 { return matches[0] }

        // Hierarchies commonly contain a button and a nested static-text node
        // with the same label. Match the actionable button just as the regular
        // simulator resolver prefers actionable elements.
        let buttons = matches.filter { $0.role.localizedCaseInsensitiveContains("button") }
        if buttons.count == 1 { return buttons[0] }

        throw IOSDeviceCommandError.multipleMatches(
            selector: selectorDescription,
            matches: Array(matches.prefix(8).map(describe))
        )
    }

    private static func describe(_ element: DeviceElement) -> String {
        "'\(DeviceOutline.label(from: element.summary, role: element.role))' [\(element.role)]"
    }
}

public struct IOSDeviceCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ios-device",
        abstract: "Physical iOS device subcommands (experimental).",
        discussion: """
        Experimental support for driving a connected iPhone or iPad through
        the accessibility audit daemon. sim-use installs and signs no runner,
        and needs no Developer Disk Image. The device must be paired, trusted,
        unlocked and in Developer Mode; the foreground app must be
        development-signed (get-task-allow=true).
        Distribution-signed and system apps are unsupported. A Release build
        remains supported when installed with a Development profile.

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

        func validate() throws {
            guard concurrency > 0 else { throw ValidationError("--concurrency must be greater than zero") }
            guard connections > 0 else { throw ValidationError("--connections must be greater than zero") }
        }

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
            abstract: "Activate an element by accessibility label.",
            discussion: """
            Uses the same --label, --label-contains and --element-type
            vocabulary as the regular tap command. The element is resolved and
            activated inside one connection because physical-device element
            handles cannot be reused by a later process. The action is
            fire-and-forget; run 'sim-use ios-device ui' again to verify.
            """
        )

        @OptionGroup var device: DeviceOptions

        @Option(help: "Exact rendered label from ios-device ui.")
        var label: String?

        @Option(help: "Case-insensitive substring of an element label.")
        var labelContains: String?

        @Option(help: "Accessibility role used to disambiguate matching labels, for example Button.")
        var elementType: String?

        func validate() throws {
            let selectors = [label, labelContains].compactMap { $0 }
            guard selectors.count == 1 else {
                throw ValidationError("specify exactly one of --label or --label-contains")
            }
            guard selectors[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ValidationError("accessibility labels cannot be empty")
            }
            if let elementType, elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--element-type cannot be empty")
            }
        }

        func run() async throws {
            let matched = try await DeviceSession.withClient(udid: device.udid) { client in
                let elements = try await DeviceTreeFetcher(client: client).fetchTree()
                let target = try DeviceTapTargetResolver.resolve(
                    elements,
                    label: label,
                    labelContains: labelContains,
                    elementType: elementType
                )
                try await client.perform(.activate, on: target.element)
                return target.summary
            }
            print("Sent Activate to \(matched)")
        }
    }
}
