// SPDX-License-Identifier: Apache-2.0
import SimUseCore
import Testing
@testable import HarmonyOSBackend

@Suite("HarmonyTargetResolver")
struct HarmonyTargetResolverTests {
    private let screen = Outline.Frame(x: 0, y: 0, width: 1080, height: 2504)

    @Test("whitespace-collapsed label round-trips from the outline")
    func collapsedLabel() throws {
        let entries = [entry(alias: 1, role: "Button", label: "Sign In", y: 100)]

        let target = try HarmonyTargetResolver.resolve(
            selector: HarmonySelector(label: "Sign\nIn"),
            entries: entries,
            screen: screen
        )

        #expect(target.x == 250)
        #expect(target.y == 140)
    }

    @Test("frame and element type disambiguate repeated labels")
    func disambiguation() throws {
        let entries = [
            entry(alias: 1, role: "StaticText", label: "Save", y: 100),
            entry(alias: 2, role: "Button", label: "Save", y: 2000),
        ]
        let frame = try SelectorFrameFilter(specs: ["minY=0.7r"])

        let target = try HarmonyTargetResolver.resolve(
            selector: HarmonySelector(label: "Save", elementType: "Button", frame: frame),
            entries: entries,
            screen: screen
        )

        #expect(target.y == 2040)
    }

    @Test("ambiguous selectors fail instead of guessing")
    func ambiguity() {
        let entries = [
            entry(alias: 1, role: "Button", label: "Save", y: 100),
            entry(alias: 2, role: "Button", label: "Save", y: 200),
        ]

        #expect(throws: HarmonyOSError.self) {
            _ = try HarmonyTargetResolver.resolve(
                selector: HarmonySelector(label: "Save"),
                entries: entries,
                screen: screen
            )
        }
    }

    private func entry(alias: Int, role: String, label: String, y: Int) -> Outline.Entry {
        Outline.Entry(
            aliases: .init(at: alias),
            role: role,
            label: label,
            frame: .init(x: 100, y: y, width: 300, height: 80),
            region: .init(kind: "Content"),
            states: []
        )
    }
}
