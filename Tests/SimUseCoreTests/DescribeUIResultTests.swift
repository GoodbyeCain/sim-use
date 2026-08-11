// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import SimUseCore

@Suite("DescribeUIResult")
struct DescribeUIResultTests {
    @Test("compact view preserves identity and clears overlapping payloads")
    func compacted() {
        let entry = Outline.Entry(
            aliases: .init(at: 1),
            role: "Button",
            label: "Open",
            frame: .init(x: 10, y: 20, width: 30, height: 40),
            region: .init(kind: "Content"),
            states: []
        )
        let result = DescribeUIResult(
            platform: .harmonyos,
            raw: .string("raw"),
            outline: "App: com.example/MainAbility  100x200\n",
            entries: [entry],
            lists: [],
            screen: .init(x: 0, y: 0, width: 100, height: 200),
            appLabel: "com.example/MainAbility",
            appPackage: "com.example"
        )

        let compact = result.compacted()

        #expect(compact.raw == nil)
        #expect(compact.entries.isEmpty)
        #expect(compact.lists.isEmpty)
        #expect(compact.outline == result.outline)
        #expect(compact.screen == result.screen)
        #expect(compact.appLabel == result.appLabel)
        #expect(compact.appPackage == result.appPackage)
    }
}
