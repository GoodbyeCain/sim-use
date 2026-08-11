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

    @Test("tap exposes the shared selector and timing surface")
    func tapSharedOptions() throws {
        let command = try HarmonyOSTapCommand.parse([
            "--label", "Open",
            "--element-type", "Button",
            "--frame", "minY=0.5r",
            "--pre-delay", "0.1",
            "--post-delay", "0.2",
            "--wait-timeout", "2",
            "--poll-interval", "0.4",
            "--device", "hdc-target",
        ])

        #expect(command.targeting.elementLabel == "Open")
        #expect(command.targeting.elementType == "Button")
        #expect(command.targeting.frameSpecs == ["minY=0.5r"])
        #expect(command.timing.preDelay == 0.1)
        #expect(command.timing.postDelay == 0.2)
        #expect(command.timing.waitTimeout == 2)
        #expect(command.timing.pollInterval == 0.4)
    }

    @Test("compact UI output requires JSON")
    func compactUIRequiresJSON() throws {
        let command = try HarmonyOSDescribeUICommand.parse([
            "--compact", "--json", "--device", "hdc-target",
        ])
        #expect(command.output.compact)

        #expect(throws: (any Error).self) {
            _ = try HarmonyOSDescribeUICommand.parse([
                "--compact", "--device", "hdc-target",
            ])
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
