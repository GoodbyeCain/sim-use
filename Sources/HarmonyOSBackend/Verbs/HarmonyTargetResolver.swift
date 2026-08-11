// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public struct HarmonySelector: Sendable {
    public var id: String?
    public var label: String?
    public var labelContains: String?
    public var labelRegex: String?
    public var value: String?
    public var elementType: String?
    public var frame: SelectorFrameFilter?

    public init(
        id: String? = nil,
        label: String? = nil,
        labelContains: String? = nil,
        labelRegex: String? = nil,
        value: String? = nil,
        elementType: String? = nil,
        frame: SelectorFrameFilter? = nil
    ) {
        self.id = id
        self.label = label
        self.labelContains = labelContains
        self.labelRegex = labelRegex
        self.value = value
        self.elementType = elementType
        self.frame = frame
    }

    public var isEmpty: Bool {
        id == nil && label == nil && labelContains == nil && labelRegex == nil
            && value == nil && elementType == nil && frame == nil
    }
}

public enum HarmonyTargetResolutionError: LocalizedError, HintProviding, Equatable {
    case noMatches(candidates: [String])
    case multipleMatches(count: Int, candidates: [String])

    public var isRetryable: Bool { true }

    public var errorDescription: String? {
        switch self {
        case .noMatches:
            return "No HarmonyOS element matched the supplied selector."
        case .multipleMatches(let count, _):
            return "HarmonyOS selector matched \(count) elements."
        }
    }

    public var hint: String? {
        switch self {
        case .noMatches(let candidates):
            let sample = candidates.isEmpty
                ? "The current outline has no labelled candidates."
                : "Available candidates include: \(candidates.joined(separator: "; "))."
            return "Re-run `sim-use ui` to confirm the current screen and selector. \(sample)"
        case .multipleMatches(_, let candidates):
            let sample = candidates.isEmpty
                ? ""
                : " Candidates: \(candidates.joined(separator: "; "))."
            return "Add --element-type or --frame to disambiguate.\(sample)"
        }
    }
}

public enum HarmonyTargetResolver {
    public struct Target: Sendable {
        public let x: Int
        public let y: Int
        public let description: String
    }

    public static func resolve(
        connectKey: String,
        alias: String?,
        x: Int?,
        y: Int?,
        selector: HarmonySelector,
        controller: HarmonyDeviceController
    ) throws -> Target {
        if let x, let y { return Target(x: x, y: y, description: "coord") }

        if let alias, !alias.isEmpty {
            do {
                let resolved = try OutlineAliasResolver.resolve(
                    alias,
                    udid: HarmonyDeviceController.cacheKey(for: connectKey)
                )
                return Target(
                    x: Int(resolved.point.x.rounded()),
                    y: Int(resolved.point.y.rounded()),
                    description: "alias \(alias) → \(resolved.role) \"\(resolved.label)\""
                )
            } catch OutlineAliasResolver.ResolutionError.idNotCacheable(let id) {
                var idSelector = selector
                idSelector.id = id
                let result = try controller.describeUI(connectKey: connectKey, includeRaw: false)
                return try resolve(selector: idSelector, entries: result.entries, screen: result.screen)
            }
        }

        if !selector.isEmpty {
            let result = try controller.describeUI(connectKey: connectKey, includeRaw: false)
            return try resolve(selector: selector, entries: result.entries, screen: result.screen)
        }

        throw HarmonyOSError.unsupported(
            "Need at least one of: positional alias (@N / #<id>), coordinate, or selector flag."
        )
    }

    public static func resolve(
        selector: HarmonySelector,
        entries: [Outline.Entry],
        screen: Outline.Frame
    ) throws -> Target {
        var matches = entries
        if let id = selector.id {
            matches = matches.filter { $0.uniqueId == id || $0.resourceId == id }
        }
        if let label = selector.label {
            matches = SelectorTextMatcher.filterEquals(matches, query: label, text: \.label)
        }
        if let contains = selector.labelContains {
            matches = SelectorTextMatcher.filterContains(matches, needle: contains, text: \.label)
        }
        if let regex = selector.labelRegex {
            matches = matches.filter { $0.label.range(of: regex, options: .regularExpression) != nil }
        }
        if let value = selector.value {
            let exact = matches.filter { $0.value == value || $0.label == value }
            if exact.isEmpty {
                let collapsed = SelectorTextMatcher.collapseWhitespace(value)
                matches = matches.filter {
                    SelectorTextMatcher.collapseWhitespace($0.value) == collapsed
                        || SelectorTextMatcher.collapseWhitespace($0.label) == collapsed
                }
            } else {
                matches = exact
            }
        }
        if let type = selector.elementType {
            matches = matches.filter { $0.role.caseInsensitiveCompare(type) == .orderedSame }
        }
        if let frame = selector.frame {
            let resolved = frame.resolved(screen: screen)
            matches = matches.filter { resolved.contains($0.frame) }
        }
        guard !matches.isEmpty else {
            throw HarmonyTargetResolutionError.noMatches(
                candidates: candidateDescriptions(entries)
            )
        }
        guard matches.count == 1 else {
            throw HarmonyTargetResolutionError.multipleMatches(
                count: matches.count,
                candidates: candidateDescriptions(matches)
            )
        }
        let entry = matches[0]
        return Target(
            x: entry.frame.x + entry.frame.width / 2,
            y: entry.frame.y + entry.frame.height / 2,
            description: "selector → \(entry.role) \"\(entry.label)\""
        )
    }

    private static func candidateDescriptions(
        _ entries: [Outline.Entry],
        limit: Int = 8
    ) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []
        for entry in entries where !entry.label.isEmpty {
            let label = entry.label.replacingOccurrences(of: "\"", with: "\\\"")
            let candidate = "@\(entry.aliases.at) \(entry.role) \"\(label)\""
            guard seen.insert(candidate).inserted else { continue }
            candidates.append(candidate)
            if candidates.count == limit { break }
        }
        return candidates
    }
}
