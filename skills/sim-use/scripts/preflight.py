#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Non-interactive sim-use readiness checks for iOS, Android, and HarmonyOS."""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional


ONLINE_STATES = {"booted", "device", "connected", "ready"}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
VERSION_PATTERN = re.compile(
    r"\b(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?|[0-9a-f]{7,40}(?:-dirty)?)\b",
    re.IGNORECASE,
)


@dataclass
class Check:
    id: str
    description: str
    run: Callable[["Ctx"], bool]
    on_fail: str = "abort"  # abort | auto
    autofix: Optional[Callable[["Ctx"], bool]] = None
    fix_hint: str = ""


@dataclass
class Ctx:
    device: Optional[str] = None
    sim_use_bin: str = "sim-use"
    platform: Optional[str] = None
    timeout: float = 45.0
    errors: list[str] = field(default_factory=list)
    detail: str = ""
    version: str = ""

    def set_detail(self, message: str) -> None:
        self.detail = message.strip()

    def run_process(self, command: list[str]) -> Optional[subprocess.CompletedProcess[str]]:
        try:
            return subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired:
            self.set_detail(
                f"command timed out after {self.timeout:g}s: {' '.join(command)}"
            )
        except OSError as error:
            self.set_detail(f"failed to run {' '.join(command)}: {error}")
        return None

    def run_json_command(self, command: list[str]) -> Optional[dict]:
        result = self.run_process(command)
        if result is None:
            return None
        if result.returncode != 0:
            self.set_detail(result_diagnostic(result))
            return None
        try:
            envelope = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            self.set_detail(f"invalid JSON response: {error}")
            return None
        if not isinstance(envelope, dict):
            self.set_detail("JSON response is not an object")
            return None
        if envelope.get("ok") is not True:
            self.set_detail(envelope_diagnostic(envelope) or "command returned ok:false")
            return None
        return envelope

    def run_sim_use_json(self, *args: str) -> Optional[dict]:
        command = [self.sim_use_bin, *args, "--json"]
        if self.device:
            command.extend(["--device", self.device])
        if self.platform:
            command.extend(["--platform", self.platform])
        return self.run_json_command(command)


def clipped(value: str, limit: int = 600) -> str:
    value = value.strip()
    if len(value) <= limit:
        return value
    return value[:limit] + "…"


def envelope_diagnostic(envelope: dict) -> str:
    parts = []
    if envelope.get("error"):
        parts.append(f"error: {envelope['error']}")
    if envelope.get("hint"):
        parts.append(f"hint: {envelope['hint']}")
    return " | ".join(parts)


def result_diagnostic(result: subprocess.CompletedProcess[str]) -> str:
    parts = []
    stdout = result.stdout.strip()
    if stdout:
        try:
            envelope = json.loads(stdout)
            if isinstance(envelope, dict):
                detail = envelope_diagnostic(envelope)
                if detail:
                    parts.append(detail)
            else:
                parts.append(f"stdout: {clipped(stdout)}")
        except json.JSONDecodeError:
            parts.append(f"stdout: {clipped(stdout)}")
    if result.stderr.strip():
        parts.append(f"stderr: {clipped(result.stderr)}")
    if not parts:
        parts.append(f"command exited {result.returncode} without diagnostics")
    return " | ".join(parts)


def run_checks(checks: list[Check], ctx: Ctx) -> bool:
    all_passed = True
    for check in checks:
        ctx.detail = ""
        if check.run(ctx):
            print(f"  PASS  {check.description}")
            continue

        initial_detail = ctx.detail
        if check.on_fail == "auto" and check.autofix:
            print(f"  FIX   {check.description} -- attempting autofix...")
            if check.autofix(ctx):
                ctx.detail = ""
                if check.run(ctx):
                    print(f"  PASS  {check.description} (after autofix)")
                    continue
            if not ctx.detail:
                ctx.detail = initial_detail

        print(f"  FAIL  {check.description}")
        if ctx.detail:
            print(f"        detail: {ctx.detail}")
        if check.fix_hint:
            print(f"        hint: {check.fix_hint}")
        ctx.errors.append(check.id)
        all_passed = False

        if check.on_fail == "abort":
            print("\n  Aborting -- later checks depend on this one.")
            break

    return all_passed


def check_sim_use_version(ctx: Ctx) -> bool:
    if shutil.which(ctx.sim_use_bin) is None:
        ctx.set_detail(f"executable not found: {ctx.sim_use_bin}")
        return False
    result = ctx.run_process([ctx.sim_use_bin, "--version"])
    if result is None:
        return False
    if result.returncode != 0:
        ctx.set_detail(result_diagnostic(result))
        return False
    match = VERSION_PATTERN.search(result.stdout)
    if match is None:
        ctx.set_detail(f"unrecognized version output: {clipped(result.stdout)}")
        return False
    ctx.version = match.group(0)
    return True


def check_device_listed(ctx: Ctx) -> bool:
    command = [ctx.sim_use_bin, "devices", "--json"]
    if ctx.platform:
        command.extend(["--platform", ctx.platform])
    envelope = ctx.run_json_command(command)
    if envelope is None:
        return False
    data = envelope.get("data")
    devices = data.get("devices") if isinstance(data, dict) else None
    if not isinstance(devices, list):
        ctx.set_detail("devices response is missing data.devices")
        return False

    if not ctx.device:
        ready = [device for device in devices if device_state(device) in ONLINE_STATES]
        if len(ready) == 1:
            ctx.device = device_id(ready[0])
            ctx.platform = ready[0].get("platform")
            return bool(ctx.device)
        if len(ready) > 1:
            names = [f"{device.get('name')} ({device_id(device)})" for device in ready]
            ctx.set_detail(f"multiple ready devices: {', '.join(names)}")
        else:
            ctx.set_detail("no booted/connected device is available")
        return False

    matches = [device for device in devices if device_id(device) == ctx.device]
    if len(matches) == 1:
        state = device_state(matches[0])
        if state not in ONLINE_STATES:
            ctx.set_detail(f"device {ctx.device} is listed with state '{state or 'unknown'}'")
            return False
        reported_platform = matches[0].get("platform")
        if ctx.platform and reported_platform and reported_platform != ctx.platform:
            ctx.set_detail(
                f"device {ctx.device} belongs to '{reported_platform}', not '{ctx.platform}'"
            )
            return False
        ctx.platform = reported_platform or ctx.platform
        return True
    if len(matches) > 1:
        platforms = sorted({device.get("platform", "unknown") for device in matches})
        ctx.set_detail(
            f"device ID exists on multiple platforms: {', '.join(platforms)}; pass --platform"
        )
    else:
        ctx.set_detail(f"device {ctx.device} is not listed")
    return False


def device_id(device: dict) -> str:
    return device.get("deviceId") or device.get("udid") or ""


def device_state(device: dict) -> str:
    return str(device.get("state", "")).lower()


def check_harmonyos_ping(ctx: Ctx) -> bool:
    if not ctx.device:
        ctx.set_detail("HarmonyOS ping requires a resolved device")
        return False
    envelope = ctx.run_json_command([
        ctx.sim_use_bin,
        "harmonyos",
        "ping",
        "--device",
        ctx.device,
        "--json",
    ])
    if envelope is None:
        return False
    data = envelope.get("data")
    if not isinstance(data, dict) or data.get("ready") is not True:
        ctx.set_detail("HarmonyOS ping response is missing data.ready=true")
        return False
    return True


def check_ui_responds(ctx: Ctx) -> bool:
    envelope = ctx.run_sim_use_json("ui", "--compact")
    if envelope is None:
        return False
    data = envelope.get("data")
    if not isinstance(data, dict):
        ctx.set_detail("UI response is missing data")
        return False
    if ctx.platform and data.get("platform") != ctx.platform:
        ctx.set_detail(
            f"UI response platform '{data.get('platform')}' does not match '{ctx.platform}'"
        )
        return False
    if not isinstance(data.get("outline"), str) or not data["outline"].strip():
        ctx.set_detail("UI response has an empty data.outline")
        return False
    screen = data.get("screen")
    if not isinstance(screen, dict) or screen.get("width", 0) <= 0 or screen.get("height", 0) <= 0:
        ctx.set_detail("UI response has invalid data.screen dimensions")
        return False
    return True


def check_screenshot_responds(ctx: Ctx) -> bool:
    with tempfile.TemporaryDirectory(prefix="sim-use-preflight-") as directory:
        output = Path(directory) / "screen.png"
        envelope = ctx.run_sim_use_json("screenshot", "--output", str(output))
        if envelope is None:
            return False
        if not output.is_file():
            ctx.set_detail("screenshot command succeeded but did not create the requested file")
            return False
        try:
            if output.read_bytes()[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
                ctx.set_detail("screenshot output is not a PNG file")
                return False
        except OSError as error:
            ctx.set_detail(f"failed to inspect screenshot output: {error}")
            return False
    return True


def autofix_daemon_restart(ctx: Ctx) -> bool:
    if ctx.platform == "harmonyos":
        ctx.set_detail("HarmonyOS commands bypass the daemon; no daemon autofix applies")
        return False
    result = ctx.run_process([ctx.sim_use_bin, "daemon", "stop", "--all"])
    if result is None:
        return False
    if result.returncode != 0:
        ctx.set_detail(result_diagnostic(result))
        return False
    return True


def base_checks() -> list[Check]:
    return [
        Check(
            id="sim_use_version",
            description="sim-use is installed and reports a version",
            run=check_sim_use_version,
            on_fail="abort",
            fix_hint="Install or rebuild sim-use, then ensure the intended binary is on PATH.",
        ),
        Check(
            id="device_ready",
            description="target device is listed in a ready state",
            run=check_device_listed,
            on_fail="abort",
            fix_hint="Boot a simulator or connect and authorize the device, then retry.",
        ),
    ]


def readiness_checks(ctx: Ctx) -> list[Check]:
    checks = []
    if ctx.platform == "harmonyos":
        checks.append(Check(
            id="harmonyos_ping",
            description="HarmonyOS hdc shell transport responds",
            run=check_harmonyos_ping,
            on_fail="abort",
            fix_hint="Verify hdc discovery plus USB/TCP debugging authorization.",
        ))
        ui_on_fail = "abort"
        ui_autofix = None
    else:
        ui_on_fail = "auto"
        ui_autofix = autofix_daemon_restart
    checks.extend([
        Check(
            id="ui_responds",
            description="sim-use returns a valid compact UI snapshot",
            run=check_ui_responds,
            on_fail=ui_on_fail,
            autofix=ui_autofix,
            fix_hint=(
                "For iOS/Android retry after `sim-use daemon stop --all`; "
                "for HarmonyOS verify UITest dumpLayout availability."
            ),
        ),
        Check(
            id="screenshot_responds",
            description="sim-use captures a valid PNG screenshot",
            run=check_screenshot_responds,
            on_fail="abort",
            fix_hint="Verify the platform screenshot primitive and available temporary storage.",
        ),
    ])
    return checks


def main() -> None:
    parser = argparse.ArgumentParser(description="Non-interactive sim-use readiness checks")
    parser.add_argument(
        "--device",
        help="Device UDID, adb serial, or hdc connect-key (auto-detected if omitted)",
    )
    parser.add_argument(
        "--platform",
        choices=("ios", "android", "harmonyos"),
        help="Disambiguate the target backend",
    )
    parser.add_argument("--sim-use-bin", default="sim-use", help="Path to sim-use binary")
    parser.add_argument(
        "--timeout",
        type=float,
        default=45.0,
        help="Per-command timeout in seconds (default: 45)",
    )
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")

    ctx = Ctx(
        device=args.device,
        sim_use_bin=args.sim_use_bin,
        platform=args.platform,
        timeout=args.timeout,
    )

    print("sim-use preflight\n")
    passed = run_checks(base_checks(), ctx)
    if passed:
        passed = run_checks(readiness_checks(ctx), ctx)
    print()

    if passed:
        print(
            f"All checks passed. Device: {ctx.device or '(auto-resolved)'} "
            f"({ctx.platform or 'unknown'}), sim-use {ctx.version}."
        )
        print("Transport and observation are ready; continue to verify every interaction result.")
        sys.exit(0)

    print(f"Preflight failed: {', '.join(ctx.errors)}")
    sys.exit(1)


if __name__ == "__main__":
    main()
