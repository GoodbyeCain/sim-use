// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import Testing
@testable import HarmonyOSBackend

@Suite("HarmonyElementNode")
struct HarmonyElementNodeTests {
    @Test("decodes UITest dumpLayout and parses canonical bounds")
    func decodeDumpLayout() throws {
        let data = Data(Self.fixture.utf8)
        let root = try JSONDecoder().decode(HarmonyElementNode.self, from: data)

        #expect(root.frame == Outline.Frame(x: 0, y: 0, width: 1080, height: 2504))
        #expect(root.children.count == 2)
        #expect(root.children[0].frame == Outline.Frame(x: 100, y: 200, width: 400, height: 100))
        #expect(root.children[0].bool("clickable") == true)
    }

    @Test("legacy rectInScreen order is normalized")
    func legacyBounds() {
        let node = HarmonyElementNode(attributes: [
            "rectInScreen": .string("[10,210][20,120]"),
        ])
        #expect(node.frame == Outline.Frame(x: 10, y: 20, width: 200, height: 100))
    }

    static let fixture = #"""
    {
      "attributes": {
        "type": "Root",
        "bounds": "[0,0][1080,2504]",
        "bundleName": "com.example.demo",
        "abilityName": "EntryAbility",
        "visible": true
      },
      "children": [
        {
          "attributes": {
            "type": "Button",
            "bounds": "[100,200][500,300]",
            "text": "Sign\nIn",
            "id": "com.example.demo:id/sign_in",
            "accessibilityId": "sign-in-button",
            "clickable": true,
            "enabled": false,
            "visible": true
          },
          "children": []
        },
        {
          "attributes": {
            "type": "CheckBox",
            "bounds": "[100,400][300,480]",
            "description": "Remember me",
            "checkable": true,
            "checked": false,
            "visible": true
          },
          "children": []
        }
      ]
    }
    """#
}
