// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

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
        identifier: String? = nil,
        label: String? = nil,
        labelContains: String? = nil,
        elementType: String? = nil
    ) throws -> DeviceElement {
        // Elements sim-use can act on, narrowed by --element-type first (as the
        // simulator resolver does), so the selector match runs on the same pool.
        let accessible = elements.filter(\.isAccessibilityElement)
        let pool = elementType.map { type in
            accessible.filter { $0.role.localizedCaseInsensitiveCompare(type) == .orderedSame }
        } ?? accessible

        let selectorDescription: String
        let matches: [DeviceElement]
        // The button-preference tie-break only makes sense for label selectors,
        // where a button and a nested static-text node legitimately share a
        // label. An accessibility identifier is a literal, unique handle (as on
        // the simulator / Android surfaces), so a duplicate id is a genuine
        // ambiguity to report, not something to silently resolve to the button.
        let preferButtonOnAmbiguity: Bool

        if let identifier {
            // Exact, case-sensitive comparison — an identifier is literal
            // identity, not human text — trimming both sides, matching the
            // simulator's `--id` (`normalizedUniqueId == trimmed query`).
            let target = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            selectorDescription = "#\(identifier)"
            matches = pool.filter { $0.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) == target }
            preferButtonOnAmbiguity = false
        } else if let label {
            // Use the shared text-matching policy (case-sensitive, exact-first
            // with a whitespace-collapsed fallback) that the simulator and
            // Android resolvers use, so label matching does not drift per
            // platform.
            selectorDescription = "--label '\(label)'"
            matches = SelectorTextMatcher.filterEquals(pool, query: label) {
                DeviceOutline.label(from: $0.summary, role: $0.role)
            }
            preferButtonOnAmbiguity = true
        } else if let labelContains {
            selectorDescription = "--label-contains '\(labelContains)'"
            matches = SelectorTextMatcher.filterContains(pool, needle: labelContains) {
                DeviceOutline.label(from: $0.summary, role: $0.role)
            }
            preferButtonOnAmbiguity = true
        } else {
            throw IOSDeviceCommandError.missingSelector
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
        if preferButtonOnAmbiguity {
            let buttons = matches.filter { $0.role.localizedCaseInsensitiveContains("button") }
            if buttons.count == 1 { return buttons[0] }
        }

        throw IOSDeviceCommandError.multipleMatches(
            selector: selectorDescription,
            matches: Array(matches.prefix(8).map(describe))
        )
    }

    static func describe(_ element: DeviceElement) -> String {
        let id = element.identifier.map { " #\($0)" } ?? ""
        return "'\(DeviceOutline.label(from: element.summary, role: element.role))' [\(element.role)]\(id)"
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
            abstract: "Activate an element by accessibility identifier or label.",
            discussion: """
            Targeting forms, mirroring the simulator tap where the channel
            allows (there is no `@N` alias — physical-device element handles
            expire between processes — and no coordinate fallback, because the
            daemon exposes no geometry):
              * Positional `#<id>` or `--id <id>` — the accessibility
                identifier shown in `ios-device ui`. Stable across reads, so
                prefer it when a label is dynamic (a back button is labelled
                with the previous screen's title but keeps `#BackButton`).
              * `--label` / `--label-contains` — exact or substring label.
              * `--element-type` disambiguates when several elements match.
            The element is resolved and activated inside one connection because
            the handle cannot be reused later. Fire-and-forget; run
            'ios-device ui' again to verify.
            """
        )

        @OptionGroup var device: DeviceOptions

        @Argument(help: "Positional accessibility identifier, written `#<id>` as shown in ios-device ui.")
        var alias: String?

        @Option(help: "Accessibility identifier from ios-device ui (the `#id`).")
        var id: String?

        @Option(help: "Exact rendered label from ios-device ui.")
        var label: String?

        @Option(help: "Case-sensitive substring of an element label.")
        var labelContains: String?

        @Option(help: "Accessibility role used to disambiguate matches, for example Button.")
        var elementType: String?

        /// Identifier from the positional `#id` alias or the `--id` option.
        private var resolvedIdentifier: String? {
            if let id { return id }
            guard let alias else { return nil }
            return alias.hasPrefix("#") ? String(alias.dropFirst()) : alias
        }

        func validate() throws {
            if let alias, id != nil {
                throw ValidationError("specify the identifier once — either the positional `#id` or --id, not both")
            }
            if let alias, !alias.hasPrefix("#") {
                throw ValidationError("positional target must be an identifier written `#\(alias)`; there is no `@N` alias on physical devices — use `#<id>`, --label, or --label-contains")
            }
            let selectors = [resolvedIdentifier, label, labelContains].compactMap { $0 }
            guard selectors.count == 1 else {
                throw ValidationError("specify exactly one of `#id` / --id, --label, or --label-contains")
            }
            guard selectors[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ValidationError("the selector cannot be empty")
            }
            if let elementType, elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--element-type cannot be empty")
            }
        }

        func run() async throws {
            let identifier = resolvedIdentifier
            let matched = try await DeviceSession.withClient(udid: device.udid) { client in
                let elements = try await DeviceTreeFetcher(client: client).fetchTree()
                let target = try DeviceTapTargetResolver.resolve(
                    elements,
                    identifier: identifier,
                    label: label,
                    labelContains: labelContains,
                    elementType: elementType
                )
                try await client.perform(.activate, on: target.element)
                return DeviceTapTargetResolver.describe(target)
            }
            print("Sent Activate to \(matched)")
        }
    }
}
