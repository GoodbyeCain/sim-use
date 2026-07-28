// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// PR B of issue #66: explicit swipe/touch coordinates keep their
// device-native portrait default (the issue #34 acceptance contract),
// and `--coordinate-space ui` opts endpoints into the visual space
// printed by describe-ui. These tests pin the opt-in rules:
//   * native stays zero-cost — no tree fetch, no calibration;
//   * ui rides the batch-wide calibration exactly like gesture presets;
//   * ui + split touch is rejected — the two halves could straddle a
//     rotation and land in different spaces.

private let quietLogger = SimUseLogger(writeToStdErr: false)

private func makeSmallTree() throws -> [AccessibilityElement] {
    let json = """
    [{"type": "Application", "AXLabel": "App", "frame": {"x": 0, "y": 0, "width": 1376, "height": 1032}, "children": [
        {"type": "Button", "AXLabel": "Corner", "frame": {"x": 10, "y": 900, "width": 100, "height": 40}, "enabled": true}
    ]}]
    """
    return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

@MainActor
private final class CalibratorSpy {
    private(set) var calls = 0
    let result: OrientationCalibration

    init(result: OrientationCalibration) {
        self.result = result
    }

    func record() -> OrientationCalibration {
        calls += 1
        return result
    }
}

@MainActor
private func makeContext(spy: CalibratorSpy, tree: [AccessibilityElement]) -> BatchContext {
    BatchContext(
        simulatorUDID: "FAKE-UDID",
        axCachePolicy: .perBatch,
        typeSubmissionMode: .chunked,
        typeChunkSize: 200,
        fetchElements: { _, _ in tree },
        calibrator: { _, _, _ in spy.record() }
    )
}

@Suite("Touch — coordinate-space validation")
struct TouchCoordinateSpaceValidationTests {

    @Test("ui space with the atomic form validates")
    func atomicUIValidates() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: true, touchUp: true,
            delay: nil, coordinateSpace: .ui)
    }

    @Test("ui space with a split --down rejects")
    func splitDownUIRejects() {
        #expect(throws: (any Error).self) {
            try IOSSimTouchCommand.validateOptions(
                pointX: 10, pointY: 10, touchDown: true, touchUp: false,
                delay: nil, coordinateSpace: .ui)
        }
    }

    @Test("ui space with a split --up rejects")
    func splitUpUIRejects() {
        #expect(throws: (any Error).self) {
            try IOSSimTouchCommand.validateOptions(
                pointX: 10, pointY: 10, touchDown: false, touchUp: true,
                delay: nil, coordinateSpace: .ui)
        }
    }

    @Test("native space keeps the split form working")
    func splitNativeStillValidates() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: true, touchUp: false,
            delay: nil, coordinateSpace: .native)
    }
}

@Suite("Batch — swipe/touch coordinate space")
@MainActor
struct BatchCoordinateSpaceTests {
    private func parseStep(_ tokens: [String], context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    private var landscape: OrientationCalibration {
        OrientationCalibration(
            orientation: .landscapeRight,
            native: NativePortraitSize(width: 1032, height: 1376),
            probesUsed: 1,
            advisory: nil
        )
    }

    @Test("Native swipe steps stay zero-cost — no calibration")
    func nativeSwipeSkipsCalibration() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["swipe", "--from", "100,200", "--to", "300,400"], context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
    }

    @Test("ui swipe steps ride the batch-wide calibration")
    func uiSwipeCalibrates() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["swipe", "--from", "100,200", "--to", "300,400", "--coordinate-space", "ui"],
            context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 1)
    }

    @Test("ui touch steps ride the batch-wide calibration")
    func uiTouchCalibrates() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["touch", "-x", "100", "-y", "200", "--down", "--up", "--coordinate-space", "ui"],
            context: context)

        #expect(primitives.count == 3)
        #expect(spy.calls == 1)
    }

    @Test("ui swipe with an unreachable tree degrades with a recorded advisory")
    func uiSwipeFetchFailureDegrades() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in throw CLIError(errorDescription: "no simulator") },
            calibrator: { _, _, _ in spy.record() }
        )

        let primitives = try await parseStep(
            ["swipe", "--from", "100,200", "--to", "300,400", "--coordinate-space", "ui"],
            context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
        #expect(context.commandAdvisories.count == 1)
        #expect(context.commandAdvisories.first?.kind == .orientationCalibrationFallback)
    }

    @Test("Split touch steps in ui space are rejected at parse time")
    func splitTouchUIRejectsInBatch() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        await #expect(throws: (any Error).self) {
            _ = try await parseStep(
                ["touch", "-x", "100", "-y", "200", "--down", "--coordinate-space", "ui"],
                context: context)
        }
    }
}
