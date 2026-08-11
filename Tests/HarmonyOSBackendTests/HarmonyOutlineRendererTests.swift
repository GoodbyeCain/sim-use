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

        #expect(outline.appLabel == "com.example.demo/EntryAbility")
        #expect(outline.text.hasPrefix("App: com.example.demo/EntryAbility  1080x2504"))
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

    @Test("non-clickable leaf aliases activate the nearest clickable ancestor")
    func clickableAncestorActivationPoint() throws {
        let root = node(
            bounds: "[0,0][1080,2504]",
            children: [
                node(
                    bounds: "[23,430][282,705]",
                    clickable: true,
                    id: "AppIconCommonView_com.example.app.MainAbility",
                    children: [
                        node(
                            bounds: "[65,629][240,673]",
                            text: "Example App",
                            type: "Text"
                        ),
                    ]
                ),
            ]
        )

        let rendered = HarmonyOutlineRenderer.renderWithActivationPoints(root: root)
        let textEntry = try #require(rendered.outline.entries.first { $0.label == "Example App" })
        let payload = rendered.cachePayload(
            udid: "harmonyos:test",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let cached = try #require(payload.entries.first { $0.aliases.at == textEntry.aliases.at })

        #expect(textEntry.frame == Outline.Frame(x: 65, y: 629, width: 175, height: 44))
        #expect(cached.x == 152)
        #expect(cached.y == 567)
    }

    @Test("clickable leaves keep their own activation point")
    func clickableLeafActivationPoint() throws {
        let root = node(
            bounds: "[0,0][1080,2504]",
            clickable: true,
            children: [
                node(
                    bounds: "[100,200][300,400]",
                    clickable: true,
                    text: "Open",
                    type: "Button"
                ),
            ]
        )

        let rendered = HarmonyOutlineRenderer.renderWithActivationPoints(root: root)
        let entry = try #require(rendered.outline.entries.first { $0.label == "Open" })
        let point = try #require(rendered.activationPoints[entry.aliases.at])

        #expect(point == .init(x: 200, y: 300))
    }

    @Test("disabled ancestors do not promote descendant aliases")
    func disabledAncestorDoesNotPromote() throws {
        let root = node(
            bounds: "[0,0][1080,2504]",
            clickable: true,
            children: [
                node(
                    bounds: "[20,100][500,500]",
                    clickable: true,
                    enabled: false,
                    children: [
                        node(
                            bounds: "[50,400][250,450]",
                            text: "Unavailable",
                            type: "Text"
                        ),
                    ]
                ),
            ]
        )

        let rendered = HarmonyOutlineRenderer.renderWithActivationPoints(root: root)
        let entry = try #require(rendered.outline.entries.first { $0.label == "Unavailable" })
        let point = try #require(rendered.activationPoints[entry.aliases.at])

        #expect(point == .init(x: 150, y: 425))
    }

    @Test("full-screen clickable wrappers do not capture leaf aliases")
    func fullScreenWrapperDoesNotPromote() throws {
        let root = node(
            bounds: "[0,0][1080,2504]",
            clickable: true,
            children: [
                node(
                    bounds: "[40,100][240,150]",
                    text: "Status",
                    type: "Text"
                ),
            ]
        )

        let rendered = HarmonyOutlineRenderer.renderWithActivationPoints(root: root)
        let entry = try #require(rendered.outline.entries.first { $0.label == "Status" })
        let point = try #require(rendered.activationPoints[entry.aliases.at])

        #expect(point == .init(x: 140, y: 125))
    }

    private func node(
        bounds: String,
        clickable: Bool = false,
        enabled: Bool = true,
        id: String? = nil,
        text: String? = nil,
        type: String? = nil,
        children: [HarmonyElementNode] = []
    ) -> HarmonyElementNode {
        var attributes: [String: JSONValue] = [
            "bounds": .string(bounds),
            "clickable": .bool(clickable),
            "enabled": .bool(enabled),
            "visible": .bool(true),
        ]
        if let id { attributes["id"] = .string(id) }
        if let text { attributes["text"] = .string(text) }
        if let type { attributes["type"] = .string(type) }
        return HarmonyElementNode(attributes: attributes, children: children)
    }
}
