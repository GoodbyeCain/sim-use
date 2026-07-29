// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import AVFoundation

@Suite("Android Record Video Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidRecordVideoTests {
    @Test("android record-video produces a loadable MP4 with a video track")
    func recordVideoSubcommand() async throws {
        let result = try await recordForDuration(arguments: ["android", "record-video"], duration: 4.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("Recording Android device"))
        #expect(result.fileSize > 10_000, "recorded file should be non-empty, got \(result.fileSize)")
        try await Self.expectValidMP4(at: result.outputURL)
    }

    @Test("top-level record-video routes an adb serial to the same engine")
    func recordVideoTopLevel() async throws {
        let result = try await recordForDuration(arguments: ["record-video"], duration: 4.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("Recording Android device"))
        try await Self.expectValidMP4(at: result.outputURL)
    }

    @Test("recording survives a screenrecord segment restart with one continuous MP4")
    func recordAcrossSegmentRestart() async throws {
        // 2-second forced segments over a ~6 s recording guarantee at
        // least one restart; the muxer must keep PTS continuous and the
        // finalized file must stay loadable.
        let result = try await recordForDuration(
            arguments: ["android", "record-video"],
            duration: 6.0,
            environment: ["SIM_USE_SCREENRECORD_TIME_LIMIT": "2"]
        )
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("restarting"), "expected a forced segment restart, stderr: \(result.stderr)")
        try await Self.expectValidMP4(at: result.outputURL)
    }

    // MARK: - Helpers

    private static func expectValidMP4(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        #expect(!tracks.isEmpty, "mp4 has no tracks (moov atom likely missing)")
        #expect(tracks.contains { $0.mediaType == .video }, "mp4 has no video track")
    }

    private func recordForDuration(
        arguments: [String],
        duration: TimeInterval,
        environment: [String: String] = [:]
    ) async throws -> (outputURL: URL, fileSize: Int, stderr: String, exitCode: Int32) {
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-android-record-\(UUID().uuidString).mp4")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = arguments + ["--device", serial, "--output", outputURL.path]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        process.terminate()

        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 15.0,
            description: "record-video did not exit after SIGTERM"
        )

        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return (outputURL: outputURL, fileSize: size, stderr: stderrText, exitCode: process.terminationStatus)
    }
}
