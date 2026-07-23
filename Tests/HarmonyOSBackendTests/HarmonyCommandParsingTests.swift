// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import HarmonyOSBackend

@Suite("HarmonyOS command parsing")
struct HarmonyCommandParsingTests {
    @Test("ui alias resolves to describe-ui")
    func uiAlias() throws {
        let command = try HarmonyOSCommand.parseAsRoot([
            "ui", "--device", "hdc-target", "--json",
        ])
        #expect(command is HarmonyOSDescribeUICommand)
    }

    @Test("tap requires exactly one targeting mode")
    func tapTargetingMode() {
        do {
            _ = try HarmonyOSTapCommand.parse([
                "@1", "--point", "100,200", "--device", "hdc-target",
            ])
            Issue.record("Expected conflicting targeting modes to fail")
        } catch {
            // Expected.
        }
    }

    @Test("multi-touch rejects non-finite coordinates")
    func multiTouchCoordinates() {
        do {
            _ = try HarmonyOSMultiTouchCommand.parse([
                "--x1", "inf", "--y1", "0",
                "--x2", "10", "--y2", "10",
                "--x1-end", "20", "--y1-end", "20",
                "--x2-end", "30", "--y2-end", "30",
                "--device", "hdc-target",
            ])
            Issue.record("Expected non-finite coordinates to fail")
        } catch {
            // Expected.
        }
    }
}
