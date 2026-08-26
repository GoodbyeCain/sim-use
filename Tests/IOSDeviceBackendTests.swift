// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import Testing
@testable import iOSDeviceBackend

@Suite("Physical iOS device backend")
struct IOSDeviceBackendTests {
    @Test("an empty hierarchy fails with the development-signing requirement")
    func emptyHierarchyFailsLoudly() async {
        let client = AXAuditClient(transport: HierarchyTransport(result: .empty))

        do {
            _ = try await DeviceTreeFetcher(client: client).fetchTree()
            Issue.record("expected an empty hierarchy to fail")
        } catch {
            #expect(error.localizedDescription.contains("get-task-allow=true"))
            #expect(error.localizedDescription.contains("unlocked"))
        }
    }

    @Test("hierarchy transport failures are not flattened into an empty tree")
    func hierarchyFailurePropagates() async {
        let client = AXAuditClient(transport: HierarchyTransport(result: .failure))

        do {
            _ = try await DeviceTreeFetcher(client: client).fetchTree()
            Issue.record("expected the hierarchy read to fail")
        } catch {
            #expect(error is HierarchyTransport.Failure)
        }
    }

    @Test("command help marks physical-device support as experimental and development-only")
    func commandHelpStatesSupportBoundary() async throws {
        let result = try await TestHelpers.runSimUseCommand("ios-device --help")

        #expect(result.output.localizedCaseInsensitiveContains("experimental"))
        #expect(result.output.contains("development-signed"))
        #expect(result.output.contains("get-task-allow=true"))
    }

    @Test("only positive DTX conversation indices are replies")
    func dtxReplyClassificationUsesConversationIndex() {
        var event = DTXFraming.Header()
        event.identifier = 42
        event.conversationIndex = 0

        var reply = event
        reply.conversationIndex = 1

        #expect(!event.isReply)
        #expect(reply.isReply)
    }

    @Test("device discovery settles only after the last attachment is quiet")
    func deviceDiscoveryUsesAQuiescenceWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = AttachmentQuiescence<String>(quietInterval: 0.25)

        let firstArrival = tracker.observe(["first"], at: start)
        let beforeFirstSettles = tracker.observe(["first"], at: start.addingTimeInterval(0.24))
        let secondArrival = tracker.observe(["first", "second"], at: start.addingTimeInterval(0.24))
        let beforeSecondSettles = tracker.observe(["first", "second"], at: start.addingTimeInterval(0.48))
        let settled = tracker.observe(["first", "second"], at: start.addingTimeInterval(0.50))

        #expect(!firstArrival)
        #expect(!beforeFirstSettles)
        #expect(!secondArrival)
        #expect(!beforeSecondSettles)
        #expect(settled)
    }

    @Test("discovery bails once the empty-grace window elapses with no device")
    func discoveryBailsWhenEmpty() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var discovery = AttachmentDiscovery<String>(quietInterval: 0.25, emptyGrace: 1.0)

        #expect(discovery.step([], at: t0) == .keepWaiting)
        #expect(discovery.step([], at: t0.addingTimeInterval(0.9)) == .keepWaiting)
        #expect(discovery.step([], at: t0.addingTimeInterval(1.0)) == .bailEmpty)
    }

    @Test("a device seen before the grace prevents the empty bail and settles")
    func discoverySettlesWhenDeviceAppears() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var discovery = AttachmentDiscovery<String>(quietInterval: 0.25, emptyGrace: 1.0)

        #expect(discovery.step([], at: t0) == .keepWaiting)
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(0.1)) == .keepWaiting)
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(0.35)) == .settled)
    }

    @Test("a device appearing at the grace boundary latches sawAny and never bails")
    func discoveryLateDeviceStillSettles() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var discovery = AttachmentDiscovery<String>(quietInterval: 0.25, emptyGrace: 1.0)

        #expect(discovery.step([], at: t0) == .keepWaiting)
        // Device shows up exactly at the grace boundary: sawAny latches, so we
        // must not bail; the quiescence window then settles it.
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(1.0)) == .keepWaiting)
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(1.3)) == .settled)
    }

    @Test("exact label matching prefers the button over duplicate static text")
    func exactLabelPrefersButton() throws {
        let text = element(1, summary: "Friends Static Text", role: "Static Text")
        let button = element(2, summary: "Friends Button", role: "Button")

        let resolved = try DeviceTapTargetResolver.resolve(
            [text, button],
            label: "Friends",
            labelContains: nil,
            elementType: nil
        )

        #expect(resolved.element == button.element)
    }

    @Test("element type narrows a contains selector")
    func elementTypeNarrowsContainsSelector() throws {
        let button = element(1, summary: "Friends Button", role: "Button")
        let header = element(2, summary: "Friends Header", role: "Header")

        let resolved = try DeviceTapTargetResolver.resolve(
            [button, header],
            label: nil,
            labelContains: "Friend",
            elementType: "Header"
        )

        #expect(resolved.element == header.element)
    }

    @Test("ambiguous and missing tap targets are runtime errors, not usage errors")
    func tapResolutionFailsLoudly() {
        let first = element(1, summary: "Save Button", role: "Button")
        let second = element(2, summary: "Save Button", role: "Button")

        for (elements, needle) in [([first, second], "Save"), ([first], "Missing")] {
            do {
                _ = try DeviceTapTargetResolver.resolve(
                    elements,
                    label: needle,
                    labelContains: nil,
                    elementType: nil
                )
                Issue.record("expected tap target resolution to fail")
            } catch {
                #expect(error is IOSDeviceCommandError)
                #expect(!(error is ValidationError))
            }
        }
    }

    @Test("physical-device outline does not advertise unusable cross-session aliases")
    func outlineOmitsAliases() {
        let rendered = DeviceOutline(elements: [
            element(1, summary: "Friends Button", role: "Button"),
        ]).rendered()

        #expect(!rendered.contains("@1"))
        #expect(rendered.contains("Button  \"Friends\""))
    }

    @Test("tap help uses the shared label selector vocabulary")
    func tapHelpUsesStandardSelectors() async throws {
        let result = try await TestHelpers.runSimUseCommand("ios-device tap --help")

        #expect(result.output.contains("--label <label>"))
        #expect(result.output.contains("--label-contains <label-contains>"))
        #expect(result.output.contains("--element-type <element-type>"))
        #expect(!result.output.contains("--text"))
    }

    @Test("invalid hierarchy tuning fails before device discovery")
    func invalidHierarchyTuningIsAUsageError() async throws {
        for option in ["--concurrency 0", "--connections 0"] {
            let result = try await TestHelpers.runSimUseCommandAllowFailure(
                "ios-device ui \(option) --device not-a-device"
            )

            #expect(result.exitCode != 0)
            #expect(result.output.contains("greater than zero"))
            #expect(!result.output.contains("no physical iOS device"))
        }
    }

    @Test("device selection errors tell the user how to recover")
    func deviceSelectionErrorsAreActionable() {
        let none = DeviceSessionError.noDevices.localizedDescription
        let multiple = DeviceSessionError.selectionRequired(available: ["device-a", "device-b"]).localizedDescription

        #expect(none.contains("no physical iOS devices"))
        #expect(multiple.contains("--device"))
        #expect(multiple.contains("device-a"))
        #expect(multiple.contains("device-b"))
    }

    private func element(
        _ tokenByte: UInt8,
        summary: String,
        role: String,
        isIgnored: Bool = false
    ) -> DeviceElement {
        DeviceElement(
            element: AXAuditElement(token: Data(repeating: tokenByte, count: 20)),
            summary: summary,
            role: role,
            depth: 0,
            parent: nil,
            isIgnored: isIgnored
        )
    }
}

private actor HierarchyTransport: DTXInvoking {
    enum Result {
        case empty
        case failure
    }

    enum Failure: Error {
        case hierarchyReadFailed
    }

    private let result: Result
    private let root = AXAuditElement(token: Data(repeating: 0x01, count: 20))

    init(result: Result) {
        self.result = result
    }

    func invoke(
        _ selector: String,
        arguments: [AXAuditValue],
        expectsReply: Bool
    ) async throws -> AXAuditValue {
        switch selector {
        case "deviceFetchSpecialElement:":
            return root.encoded
        case "deviceElement:valueForAttribute:":
            switch result {
            case .empty:
                return .null
            case .failure:
                throw Failure.hierarchyReadFailed
            }
        default:
            return .null
        }
    }
}
