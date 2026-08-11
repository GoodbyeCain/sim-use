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

        do {
            _ = try HarmonyTargetResolver.resolve(
                selector: HarmonySelector(label: "Save"),
                entries: entries,
                screen: screen
            )
            Issue.record("Expected multiple matches to fail")
        } catch let error as HarmonyTargetResolutionError {
            #expect(error.errorDescription == "HarmonyOS selector matched 2 elements.")
            #expect(error.hint?.contains("@1 Button \"Save\"") == true)
            #expect(error.hint?.contains("--frame") == true)
        } catch {
            Issue.record("Expected HarmonyTargetResolutionError, got \(error)")
        }
    }

    @Test("missing selectors include actionable candidate hints")
    func noMatchHint() {
        let entries = [entry(alias: 1, role: "Button", label: "Save", y: 100)]

        do {
            _ = try HarmonyTargetResolver.resolve(
                selector: HarmonySelector(label: "Send"),
                entries: entries,
                screen: screen
            )
            Issue.record("Expected no match to fail")
        } catch let error as HarmonyTargetResolutionError {
            #expect(error.errorDescription == "No HarmonyOS element matched the supplied selector.")
            #expect(error.hint?.contains("Re-run `sim-use ui`") == true)
            #expect(error.hint?.contains("@1 Button \"Save\"") == true)
        } catch {
            Issue.record("Expected HarmonyTargetResolutionError, got \(error)")
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
