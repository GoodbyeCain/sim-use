// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Preflight Script Tests")
struct PreflightScriptTests {
    @Test("device listing stays unscoped while observation checks target the resolved device")
    func deviceListingDoesNotReceiveDeviceScopedOptions() async throws {
        let fixture = try Fixture(
            script: successScript(platform: "ios", device: "target-device", state: "Booted")
        )
        defer { fixture.remove() }

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --device target-device --sim-use-bin \(fixture.executable.path)",
            allowFailure: true
        )

        #expect(result.exitCode == 0, "preflight should pass with fake sim-use: \(result.output)")
        #expect(result.output.contains("sim-use 0.11.0"))
        #expect(result.output.contains("Transport and observation are ready"))

        let log = try fixture.logContents()
        #expect(log.contains("--version\n"))
        #expect(log.contains("devices --json\n"))
        #expect(!log.contains("devices --json --device target-device"))
        #expect(log.contains("ui --compact --json --device target-device --platform ios"))
        #expect(log.contains("screenshot --output"))
    }

    @Test("HarmonyOS preflight adds ping and never invokes daemon autofix")
    func harmonyOSPlatformChecks() async throws {
        let fixture = try Fixture(
            script: successScript(platform: "harmonyos", device: "hdc-target", state: "Connected")
        )
        defer { fixture.remove() }

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --platform harmonyos --device hdc-target --sim-use-bin \(fixture.executable.path)",
            allowFailure: true
        )

        #expect(result.exitCode == 0, "HarmonyOS preflight should pass: \(result.output)")
        let log = try fixture.logContents()
        #expect(log.contains("devices --json --platform harmonyos"))
        #expect(log.contains("harmonyos ping --device hdc-target --json"))
        #expect(log.contains("ui --compact --json --device hdc-target --platform harmonyos"))
        #expect(!log.contains("daemon stop"))
    }

    @Test("explicit offline devices fail before UI checks")
    func explicitOfflineDeviceFails() async throws {
        let fixture = try Fixture(
            script: successScript(platform: "harmonyos", device: "hdc-target", state: "Offline")
        )
        defer { fixture.remove() }

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --platform harmonyos --device hdc-target --sim-use-bin \(fixture.executable.path)",
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("state 'offline'"))
        let log = try fixture.logContents()
        #expect(!log.contains("harmonyos ping"))
        #expect(!log.contains("ui --compact"))
    }

    @Test("structured command errors preserve error and hint")
    func structuredErrorsAreVisible() async throws {
        let script = """
        #!/bin/bash
        printf '%s\\n' "$*" >> "__LOG_PATH__"
        if [[ "$1" == "--version" ]]; then echo '0.11.0'; exit 0; fi
        if [[ "$1" == "devices" ]]; then
          echo '{"ok":true,"data":{"devices":[{"deviceId":"hdc-target","name":"Harmony","platform":"harmonyos","state":"Connected"}]}}'
          exit 0
        fi
        if [[ "$1" == "harmonyos" && "$2" == "ping" ]]; then
          echo '{"ok":true,"data":{"deviceId":"hdc-target","ready":true}}'
          exit 0
        fi
        if [[ "$1" == "ui" ]]; then
          echo '{"ok":false,"error":"UITest unavailable","hint":"Enable developer mode"}'
          exit 1
        fi
        exit 4
        """
        let fixture = try Fixture(script: script)
        defer { fixture.remove() }

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --platform harmonyos --device hdc-target --sim-use-bin \(fixture.executable.path)",
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("error: UITest unavailable"))
        #expect(result.output.contains("hint: Enable developer mode"))
        #expect(!result.output.contains("attempting autofix"))
    }

    @Test("external commands are bounded by the configured timeout")
    func commandTimeout() async throws {
        let script = """
        #!/bin/bash
        sleep 1
        echo '0.11.0'
        """
        let fixture = try Fixture(script: script)
        defer { fixture.remove() }

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --timeout 0.05 --sim-use-bin \(fixture.executable.path)",
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("timed out after 0.05s"))
    }

    @Test("source-build Git identities are accepted as versions")
    func sourceBuildVersion() async throws {
        let script = successScript(platform: "ios", device: "target-device", state: "Booted")
            .replacingOccurrences(of: "echo '0.11.0'", with: "echo '9a83c6f-dirty'")
        let fixture = try Fixture(script: script)
        defer { fixture.remove() }

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --device target-device --sim-use-bin \(fixture.executable.path)",
            allowFailure: true
        )

        #expect(result.exitCode == 0, "source-build identity should pass: \(result.output)")
        #expect(result.output.contains("sim-use 9a83c6f-dirty"))
    }

    private func successScript(platform: String, device: String, state: String) -> String {
        """
        #!/bin/bash
        printf '%s\\n' "$*" >> "__LOG_PATH__"

        if [[ "$1" == "--version" ]]; then
          echo '0.11.0'
          exit 0
        fi

        if [[ "$1" == "devices" ]]; then
          echo '{"ok":true,"data":{"devices":[{"deviceId":"\(device)","name":"Test Device","platform":"\(platform)","state":"\(state)"}]}}'
          exit 0
        fi

        if [[ "$1" == "harmonyos" && "$2" == "ping" ]]; then
          echo '{"ok":true,"data":{"deviceId":"\(device)","ready":true}}'
          exit 0
        fi

        if [[ "$1" == "ui" ]]; then
          echo '{"ok":true,"data":{"platform":"\(platform)","outline":"App: Test  100x200\\n","screen":{"x":0,"y":0,"width":100,"height":200}}}'
          exit 0
        fi

        if [[ "$1" == "screenshot" ]]; then
          output=''
          index=1
          while [[ $index -le $# ]]; do
            argument="${!index}"
            if [[ "$argument" == "--output" ]]; then
              next=$((index + 1))
              output="${!next}"
              break
            fi
            index=$((index + 1))
          done
          printf '\\211PNG\\r\\n\\032\\n' > "$output"
          echo '{"ok":true,"data":{"path":"screen.png"}}'
          exit 0
        fi

        if [[ "$1" == "daemon" && "$2" == "stop" ]]; then
          echo '{"ok":true,"data":{}}'
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 4
        """
    }
}

private struct Fixture {
    let directory: URL
    let executable: URL
    let log: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-preflight-tests-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("sim-use")
        log = directory.appendingPathComponent("sim-use-args.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rendered = script.replacingOccurrences(of: "__LOG_PATH__", with: log.path)
        try rendered.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    func logContents() throws -> String {
        guard FileManager.default.fileExists(atPath: log.path) else { return "" }
        return try String(contentsOf: log, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
