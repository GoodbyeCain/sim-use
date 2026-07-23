// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HarmonyOSBackend

@Suite("Hdc")
struct HdcTests {
    @Test("list targets -v parser preserves connection metadata")
    func parseVerboseTargets() {
        let output = """
        connect-key1            USB     Connected       localhost       hdc
        127.0.0.1:5555          TCP     Offline         emulator-1      hdc
        connect-key2            USB     Ready           Mate60          hdc
        """

        let targets = Hdc.parseTargets(output)

        #expect(targets.count == 3)
        #expect(targets[0].connectKey == "connect-key1")
        #expect(targets[0].connection == "USB")
        #expect(targets[0].state == "Connected")
        #expect(targets[0].name == "connect-key1")
        #expect(targets[0].isOnline)
        #expect(targets[1].name == "emulator-1")
        #expect(!targets[1].isOnline)
        #expect(targets[2].isOnline)
    }

    @Test("empty sentinel is not exposed as a target")
    func emptySentinel() {
        #expect(Hdc.parseTargets("[Empty]\n").isEmpty)
    }

    @Test("shell passes target and remote arguments without host-shell interpolation")
    func shellArgumentForwarding() throws {
        let fixture = try FakeHdc()
        defer { fixture.remove() }
        let controller = HarmonyDeviceController(hdc: Hdc(binaryPath: fixture.executable.path))

        try controller.typeText(connectKey: "device-1", text: "hello 'Harmony OS' 世界")

        let arguments = try fixture.arguments()
        #expect(arguments == [
            "-t", "device-1", "shell", "uitest", "uiInput", "text",
            "'hello '\\''Harmony OS'\\'' 世界'",
        ])
    }

    @Test("touch gestures map seconds to documented uinput milliseconds")
    func uinputArguments() throws {
        let fixture = try FakeHdc()
        defer { fixture.remove() }
        let controller = HarmonyDeviceController(hdc: Hdc(binaryPath: fixture.executable.path))

        try controller.swipe(
            connectKey: "device-1",
            startX: 10,
            startY: 20,
            endX: 300,
            endY: 400,
            duration: 0.3
        )
        #expect(try fixture.arguments() == [
            "-t", "device-1", "shell", "uinput", "-T", "-m",
            "10", "20", "300", "400", "-k", "0", "300",
        ])

        try controller.multiTouch(
            connectKey: "device-1",
            startP1: (10, 20),
            startP2: (30, 40),
            endP1: (110, 120),
            endP2: (130, 140),
            duration: 0.5
        )
        #expect(try fixture.arguments() == [
            "-t", "device-1", "shell", "uinput", "-T", "-m",
            "10", "20", "110", "120", "30", "40", "130", "140",
            "-k", "0", "500",
        ])
    }

    @Test("hdc logical failures are errors even when the process exits zero")
    func logicalFailure() throws {
        let fixture = try FakeHdc(logicalFailure: true)
        defer { fixture.remove() }
        let hdc = Hdc(binaryPath: fixture.executable.path)

        do {
            _ = try hdc.shell(target: "missing", args: ["echo", "ready"])
            Issue.record("Expected [Fail] output to throw")
        } catch let error as HarmonyOSError {
            guard case .commandFailed(_, let exitCode, let message) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(exitCode == 0)
            #expect(message.contains("Not match target"))
        }
    }
}

private struct FakeHdc {
    let directory: URL
    let executable: URL
    let log: URL

    init(logicalFailure: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-hdc-tests-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("hdc")
        log = directory.appendingPathComponent("arguments.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let failureOutput = logicalFailure
            ? "printf '%s\\n' '[Fail]Not match target founded, check connect-key please'"
            : ""
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(log.path)'
        \(failureOutput)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func arguments() throws -> [String] {
        try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
