// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public enum HarmonyOutlineRenderer {
    public struct Options: Sendable {
        public var filterOffscreen: Bool
        public init(filterOffscreen: Bool = true) { self.filterOffscreen = filterOffscreen }
        public static let `default` = Options()
    }

    private struct Candidate {
        let node: HarmonyElementNode
        let frame: Outline.Frame
        let tapFrame: Outline.Frame?
        let depth: Int
        let role: String
        let label: String
    }

    struct ActivationPoint: Equatable, Sendable {
        let x: Int
        let y: Int
    }

    struct RenderedOutline: Equatable, Sendable {
        let outline: Outline
        let activationPoints: [Int: ActivationPoint]

        func cachePayload(
            udid: String,
            capturedAt: Date = Date()
        ) -> OutlineCache.Payload {
            let base = OutlineCache.makePayload(
                outline: outline,
                udid: udid,
                capturedAt: capturedAt
            )
            let entries = base.entries.map { entry in
                let point = activationPoints[entry.aliases.at]
                return OutlineCache.Payload.Entry(
                    aliases: entry.aliases,
                    role: entry.role,
                    label: entry.label,
                    x: point?.x ?? entry.x,
                    y: point?.y ?? entry.y,
                    w: entry.w,
                    h: entry.h
                )
            }
            return OutlineCache.Payload(
                version: base.version,
                udid: base.udid,
                capturedAt: base.capturedAt,
                screen: base.screen,
                entries: entries,
                orientation: base.orientation
            )
        }
    }

    private struct DedupKey: Hashable {
        let role: String
        let label: String
        let frame: Outline.Frame
    }

    public static func render(root: HarmonyElementNode, options: Options = .default) -> Outline {
        renderWithActivationPoints(root: root, options: options).outline
    }

    static func renderWithActivationPoints(
        root: HarmonyElementNode,
        options: Options = .default
    ) -> RenderedOutline {
        let screen = screenFrame(root)
        let appPackage = firstNonEmpty(root, keyPath: \HarmonyElementNode.bundleName) ?? "HarmonyOS App"
        let abilityName = firstNonEmpty(root, keyPath: \HarmonyElementNode.abilityName)
        let appLabel = appIdentity(package: appPackage, ability: abilityName)

        var candidates: [Candidate] = []
        walk(
            root,
            depth: 0,
            screen: screen,
            options: options,
            inheritedTapFrame: nil,
            interactionBlocked: false,
            into: &candidates
        )
        candidates.sort {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            return $0.depth < $1.depth
        }

        var seen = Set<DedupKey>()
        var entries: [Outline.Entry] = []
        var activationPoints: [Int: ActivationPoint] = [:]
        for candidate in candidates {
            let label = SelectorTextMatcher.collapseWhitespace(candidate.label)
            let key = DedupKey(role: candidate.role, label: label, frame: candidate.frame)
            guard seen.insert(key).inserted else { continue }
            let states = stateTags(candidate.node)
            let resourceID = candidate.node.id.isEmpty ? nil : HarmonyElementNode.shortID(candidate.node.id)
            let uniqueID = candidate.node.accessibilityId.isEmpty ? nil : candidate.node.accessibilityId
            let value = candidate.node.text.isEmpty || candidate.node.text == candidate.label
                ? nil
                : candidate.node.text
            let alias = entries.count + 1
            entries.append(Outline.Entry(
                aliases: Outline.Aliases(at: alias),
                role: candidate.role,
                label: label,
                frame: candidate.frame,
                region: region(for: candidate.frame, screen: screen),
                states: states,
                uniqueId: uniqueID,
                value: value,
                resourceId: resourceID,
                hint: candidate.node.hint.isEmpty ? nil : candidate.node.hint,
                depth: candidate.depth
            ))
            activationPoints[alias] = activationPoint(
                semanticFrame: candidate.frame,
                tapFrame: candidate.tapFrame,
                screen: screen
            )
        }

        let text = renderText(appLabel: appLabel, screen: screen, entries: entries)
        return RenderedOutline(
            outline: Outline(
                text: text,
                entries: entries,
                screen: screen,
                appLabel: appLabel
            ),
            activationPoints: activationPoints
        )
    }

    public static func appPackage(root: HarmonyElementNode) -> String {
        firstNonEmpty(root, keyPath: \HarmonyElementNode.bundleName) ?? ""
    }

    /// HarmonyOS commonly reports every foreground component as
    /// `MainAbility`. Rendering that value alone makes unrelated apps
    /// indistinguishable, which defeats wrong-app and system-overlay checks.
    /// Keep the existing `appLabel` field but make it a stable component
    /// identity until UITest exposes a user-facing application name.
    private static func appIdentity(package: String, ability: String?) -> String {
        guard let ability, !ability.isEmpty, ability != package else { return package }
        return "\(package)/\(ability)"
    }

    private static func walk(
        _ node: HarmonyElementNode,
        depth: Int,
        screen: Outline.Frame,
        options: Options,
        inheritedTapFrame: Outline.Frame?,
        interactionBlocked: Bool,
        into output: inout [Candidate]
    ) {
        let frame = node.frame
        let blocked = interactionBlocked || node.bool("enabled") == false
        let tapFrame: Outline.Frame?
        if blocked {
            tapFrame = nil
        } else if node.bool("clickable") == true, let frame {
            tapFrame = frame
        } else {
            tapFrame = inheritedTapFrame
        }

        if let frame,
           shouldInclude(node, frame: frame, screen: screen, options: options) {
            output.append(Candidate(
                node: node,
                frame: frame,
                tapFrame: tapFrame,
                depth: depth,
                role: canonicalRole(node),
                label: node.primaryLabel
            ))
        }
        for child in node.children {
            walk(
                child,
                depth: depth + 1,
                screen: screen,
                options: options,
                inheritedTapFrame: tapFrame,
                interactionBlocked: blocked,
                into: &output
            )
        }
    }

    private static func activationPoint(
        semanticFrame: Outline.Frame,
        tapFrame: Outline.Frame?,
        screen: Outline.Frame
    ) -> ActivationPoint {
        let semanticCenter = ActivationPoint(
            x: semanticFrame.x + semanticFrame.width / 2,
            y: semanticFrame.y + semanticFrame.height / 2
        )
        guard let tapFrame else { return semanticCenter }
        guard tapFrame != semanticFrame else {
            return ActivationPoint(
                x: tapFrame.x + tapFrame.width / 2,
                y: tapFrame.y + tapFrame.height / 2
            )
        }

        let containsSemanticCenter = semanticCenter.x >= tapFrame.x
            && semanticCenter.x < tapFrame.x + tapFrame.width
            && semanticCenter.y >= tapFrame.y
            && semanticCenter.y < tapFrame.y + tapFrame.height
        guard containsSemanticCenter else { return semanticCenter }

        let screenArea = Double(screen.width) * Double(screen.height)
        let tapArea = Double(tapFrame.width) * Double(tapFrame.height)
        if screenArea > 0, tapArea / screenArea >= 0.9 {
            // A full-screen clickable wrapper is commonly structural. Moving a
            // text alias to its center would be less reliable than preserving
            // the leaf point, so only tightly-scoped ancestors are promoted.
            return semanticCenter
        }
        return ActivationPoint(
            x: tapFrame.x + tapFrame.width / 2,
            y: tapFrame.y + tapFrame.height / 2
        )
    }

    private static func shouldInclude(
        _ node: HarmonyElementNode,
        frame: Outline.Frame,
        screen: Outline.Frame,
        options: Options
    ) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        if node.bool("visible") == false { return false }
        if options.filterOffscreen, screen.width > 0, screen.height > 0 {
            if frame.x + frame.width <= screen.x || frame.y + frame.height <= screen.y { return false }
            if frame.x >= screen.x + screen.width || frame.y >= screen.y + screen.height { return false }
        }
        let interactive = node.bool("clickable") == true
            || node.bool("longClickable") == true
            || node.bool("scrollable") == true
            || node.bool("checkable") == true
        return !node.primaryLabel.isEmpty || node.stableID != nil || interactive
    }

    private static func canonicalRole(_ node: HarmonyElementNode) -> String {
        let lowered = node.type.lowercased()
        if lowered.contains("button") { return "Button" }
        if lowered.contains("textfield") || lowered.contains("textinput")
            || lowered.contains("textarea") || lowered.contains("search") { return "TextField" }
        if lowered.contains("checkbox") { return "CheckBox" }
        if lowered.contains("switch") || lowered.contains("toggle") { return "Switch" }
        if lowered.contains("image") { return "Image" }
        if lowered == "text" || lowered.contains("textview") { return "StaticText" }
        if lowered.contains("listitem") { return "Cell" }
        if lowered.contains("list") { return "Collection" }
        if lowered.contains("scroll") { return "ScrollView" }
        if lowered.contains("slider") { return "Slider" }
        if lowered.contains("tab") { return "Tab" }
        if node.bool("clickable") == true || node.bool("longClickable") == true { return "Button" }
        return node.type.isEmpty ? "Component" : node.type
    }

    private static func stateTags(_ node: HarmonyElementNode) -> [String] {
        var tags: [String] = []
        if node.bool("enabled") == false { tags.append("disabled") }
        if node.bool("focused") == true { tags.append("focused") }
        if node.bool("selected") == true { tags.append("selected") }
        if node.bool("checked") == true { tags.append("checked") }
        if node.bool("checkable") == true,
           node.bool("checked") == false,
           node.bool("selected") != true {
            tags.append("unchecked")
        }
        if node.bool("scrollable") == true { tags.append("scrollable") }
        if node.bool("longClickable") == true { tags.append("long-clickable") }
        return tags
    }

    private static func screenFrame(_ root: HarmonyElementNode) -> Outline.Frame {
        if let frame = root.frame, frame.width > 0, frame.height > 0 { return frame }
        var frames: [Outline.Frame] = []
        collectFrames(root, into: &frames)
        guard let first = frames.first else { return Outline.Frame(x: 0, y: 0, width: 0, height: 0) }
        let left = frames.map(\.x).min() ?? first.x
        let top = frames.map(\.y).min() ?? first.y
        let right = frames.map { $0.x + $0.width }.max() ?? first.x + first.width
        let bottom = frames.map { $0.y + $0.height }.max() ?? first.y + first.height
        return Outline.Frame(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func collectFrames(_ node: HarmonyElementNode, into output: inout [Outline.Frame]) {
        if let frame = node.frame, frame.width > 0, frame.height > 0 { output.append(frame) }
        for child in node.children { collectFrames(child, into: &output) }
    }

    private static func firstNonEmpty(
        _ node: HarmonyElementNode,
        keyPath: KeyPath<HarmonyElementNode, String>
    ) -> String? {
        let value = node[keyPath: keyPath]
        if !value.isEmpty { return value }
        for child in node.children {
            if let value = firstNonEmpty(child, keyPath: keyPath) { return value }
        }
        return nil
    }

    private static func region(for frame: Outline.Frame, screen: Outline.Frame) -> Outline.Region {
        guard screen.height > 0 else { return Outline.Region(kind: "Content") }
        let centerY = frame.y + frame.height / 2
        let inset = max(80, screen.height / 8)
        if centerY < screen.y + inset { return Outline.Region(kind: "Top") }
        if centerY >= screen.y + screen.height - inset { return Outline.Region(kind: "Bottom") }
        return Outline.Region(kind: "Content")
    }

    private static func renderText(
        appLabel: String,
        screen: Outline.Frame,
        entries: [Outline.Entry]
    ) -> String {
        var lines = ["App: \(appLabel)  \(screen.width)x\(screen.height)"]
        var previousRegion: String?
        for entry in entries {
            if entry.region.kind != previousRegion {
                lines.append("")
                lines.append("[\(entry.region.kind)]")
                previousRegion = entry.region.kind
            }
            let escaped = entry.label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            var line = "  @\(entry.aliases.at)  \(entry.role)  \"\(escaped)\""
            if let uniqueID = entry.uniqueId { line += "  #\(uniqueID)" }
            if let resourceID = entry.resourceId { line += "  :\(resourceID):" }
            line += "  (\(entry.frame.x),\(entry.frame.y) \(entry.frame.width)x\(entry.frame.height))"
            for state in entry.states { line += "  [\(state)]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
