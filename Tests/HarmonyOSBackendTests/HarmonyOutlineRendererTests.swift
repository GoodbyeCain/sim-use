// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import Testing
@testable import HarmonyOSBackend

@Suite("HarmonyOutlineRenderer")
struct HarmonyOutlineRendererTests {
    @Test("renders UITest nodes into the shared outline contract")
    func render() throws {
        let root = try JSONDecoder().decode(
            HarmonyElementNode.self,
            from: Data(HarmonyElementNodeTests.fixture.utf8)
        )

        let outline = HarmonyOutlineRenderer.render(root: root)

        #expect(outline.appLabel == "EntryAbility")
        #expect(outline.screen == Outline.Frame(x: 0, y: 0, width: 1080, height: 2504))
        #expect(outline.entries.count == 2)
        #expect(outline.entries[0].role == "Button")
        #expect(outline.entries[0].label == "Sign In")
        #expect(outline.entries[0].resourceId == "sign_in")
        #expect(outline.entries[0].uniqueId == "sign-in-button")
        #expect(outline.entries[0].states == ["disabled"])
        #expect(outline.entries[1].states == ["unchecked"])
        #expect(outline.text.contains("[disabled]"))
        #expect(!outline.text.contains("[[disabled]]"))
    }

    @Test("offscreen nodes are filtered by default")
    func offscreenFiltering() {
        let root = HarmonyElementNode(
            attributes: ["bounds": .string("[0,0][100,100]")],
            children: [
                HarmonyElementNode(attributes: [
                    "bounds": .string("[200,200][250,250]"),
                    "text": .string("Outside"),
                    "visible": .bool(true),
                ]),
            ]
        )

        #expect(HarmonyOutlineRenderer.render(root: root).entries.isEmpty)
        #expect(HarmonyOutlineRenderer.render(
            root: root,
            options: .init(filterOffscreen: false)
        ).entries.count == 1)
    }
}
