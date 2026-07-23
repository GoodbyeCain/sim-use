// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// UITest `dumpLayout` node. Attributes intentionally stay as JSONValue:
/// OpenHarmony has added fields over time, while the stable tree shape is
/// only `{attributes, children}`. Typed accessors below normalize the fields
/// sim-use consumes without rejecting newer platform payloads.
public struct HarmonyElementNode: Codable, Equatable, Sendable {
    public let attributes: [String: JSONValue]
    public let children: [HarmonyElementNode]

    public init(attributes: [String: JSONValue], children: [HarmonyElementNode] = []) {
        self.attributes = attributes
        self.children = children
    }

    public func string(_ key: String) -> String? {
        guard let value = attributes[key] else { return nil }
        switch value {
        case .string(let string): return string
        case .integer(let integer): return String(integer)
        case .double(let double): return String(double)
        case .bool(let bool): return bool ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = attributes[key] else { return nil }
        switch value {
        case .bool(let bool): return bool
        case .integer(let integer): return integer != 0
        case .string(let string):
            if string.caseInsensitiveCompare("true") == .orderedSame || string == "1" { return true }
            if string.caseInsensitiveCompare("false") == .orderedSame || string == "0" { return false }
            return nil
        case .null, .double, .array, .object: return nil
        }
    }

    public var frame: Outline.Frame? {
        if let bounds = string("bounds"), let frame = Self.parseBounds(bounds, legacyOrder: false) {
            return frame
        }
        if let bounds = string("rectInScreen"), let frame = Self.parseBounds(bounds, legacyOrder: true) {
            return frame
        }
        if case .object(let object)? = attributes["bounds"] {
            func int(_ key: String) -> Int? {
                switch object[key] {
                case .integer(let value): return Int(value)
                case .double(let value): return Int(value.rounded())
                case .string(let value): return Int(value)
                default: return nil
                }
            }
            if let left = int("left"), let top = int("top"),
               let right = int("right"), let bottom = int("bottom") {
                return Outline.Frame(
                    x: left, y: top,
                    width: max(0, right - left),
                    height: max(0, bottom - top)
                )
            }
        }
        return nil
    }

    public var type: String { string("type") ?? string("componentType") ?? "Component" }
    public var text: String { normalized(string("text")) }
    public var description: String { normalized(string("description")) }
    public var hint: String { normalized(string("hint")) }
    public var id: String { normalized(string("id")) }
    public var accessibilityId: String { normalized(string("accessibilityId")) }
    public var bundleName: String { normalized(string("bundleName")) }
    public var abilityName: String { normalized(string("abilityName")) }

    public var stableID: String? {
        if !id.isEmpty { return id }
        if !accessibilityId.isEmpty { return accessibilityId }
        return nil
    }

    public var primaryLabel: String {
        if !description.isEmpty { return description }
        if !text.isEmpty { return text }
        if !hint.isEmpty { return hint }
        if !id.isEmpty { return Self.shortID(id) }
        return ""
    }

    public static func parseBounds(_ raw: String, legacyOrder: Bool = false) -> Outline.Frame? {
        let values = raw.split { character in
            !(character.isNumber || character == "-")
        }.compactMap { Int($0) }
        guard values.count >= 4 else { return nil }
        let left = values[0]
        let top = legacyOrder ? values[2] : values[1]
        let right = legacyOrder ? values[1] : values[2]
        let bottom = values[3]
        return Outline.Frame(
            x: left, y: top,
            width: max(0, right - left),
            height: max(0, bottom - top)
        )
    }

    public static func shortID(_ raw: String) -> String {
        if let slash = raw.lastIndex(of: "/") { return String(raw[raw.index(after: slash)...]) }
        return raw
    }

    private func normalized(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "null" ? "" : trimmed
    }
}
