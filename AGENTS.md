# Development Rules

## Code quality
- No `Any` types unless absolutely necessary; upgrade dependencies rather than downgrading code to work around type errors.
- Follow Swift best practices and match the style of surrounding code.
- When adding or removing commands/options, update the README and `skills/sim-use/SKILL.md`. If the Skill starts relying on behavior newer than its current compatibility floor, also bump `MINIMUM_SIM_USE_VERSION` in `skills/sim-use/scripts/preflight.py` and extend `PreflightScriptTests`.

## Changelog
`CHANGELOG.md` is a release guide for tool users, not an implementation log. Follow [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

- Add changes under `## [Unreleased]`. Released headings use `## [x.y.z] - YYYY-MM-DD`; do not edit released sections unless the user explicitly asks.
- Start each populated version, including Unreleased, with a 1–3 sentence summary. Assume the reader reads only this summary: name the main benefits and any required migration.
- Use only non-empty subsections in this order: `### Added` / `### Changed` / `### Fixed` / `### Removed`. Put the most important changes first within each subsection.
- Write each bullet in plain English, usually 1–2 short sentences and at most about 50 words. State what users can do now or what problem is solved. Name commands or flags when useful, but explain their benefit or required action too.
- Combine related changes instead of listing every commit. Keep implementation details, investigation history and benchmark logs out of the changelog; use `docs/ai/` for technical reasoning and the README for usage details.
- Keep PR references and contributor thanks with the relevant change, including when merging or rewriting entries. Do not lose credit to save space. Describe each version as it shipped, without importing later behavior.

## Design records (`docs/ai/`)
sim-use uses AI-docs-driven development. Before a substantial feature, a contract change (daemon or bridge wire, `--json` envelope, skill compatibility floor) or a non-trivial root-cause fix, create `docs/ai/NNN-<slug>/000-plan.md` (`000-investigation.md` for a root-cause hunt) with the `write-ai-docs` skill. Record each decision when you make it, and write `001-action.md` after the work lands. Before you change code that an entry covers, read the entry. Index and layout: `docs/ai/README.md`.

## Build and test

### First-time setup

```bash
brew install xcodegen    # idb generates its Xcode project with XcodeGen
./scripts/build.sh dev   # clone idb, build XCFrameworks
make build               # build sim-use
```

The FB* XCFrameworks are static archives built without library evolution —
`build_products/` is locked to the toolchain that produced it. Re-run
`./scripts/build.sh dev` after switching Xcode versions.

### Daily workflow

```bash
make build                                           # incremental build
.build/debug/sim-use describe-ui --device $UDID      # test against a booted simulator
```

### Running tests

```bash
make test                        # unit tests (no simulator needed)
swift test --filter TapTests     # run a single test suite
```

`make test` runs `swift test --enable-code-coverage` — unit tests that exercise parsing, outline rendering, daemon protocol, and cross-platform dispatch without a live simulator.

When [xcsift](https://github.com/ldomaradzki/xcsift) is installed (`brew install xcsift` — optional, never required), `make build` / `make test` condense swift output into a TOON summary plus a coverage report. `SIM_USE_XCSIFT=0 make test` forces plain swift output.

### End-to-end tests (live device)

```bash
make e2e            # BOTH iOS + Android in sequence (needs a booted sim AND an emulator)
make e2e-ios        # iOS only — booted simulator + Playground fixture
make e2e-android    # Android only — reachable device/emulator + Playground fixture
make e2e-matrix     # iOS across Xcode 26/27 × Device Hub closed/open legs (~35 min default)
make eval           # agent evals (real `claude -p` cost; prompts before running)
```

**Run the Android emulator headless (`-no-window`) for video work.**
`screenrecord` only produces frames while SurfaceFlinger is compositing, and
with a windowed emulator that depends on the window being genuinely visible —
frames stop when it is on another Space or occluded, which makes any
automation of capture unreliable. Headless uses offscreen rendering and is
stable. Measured over 5 s of sustained interaction:

| GPU | window | frames |
|---|---|---|
| `swiftshader_indirect` | visible | 2 |
| `host` | visible | 110 |
| `host` | on another Space | 1 |
| `swiftshader_indirect` | **`-no-window`** | **31** |

Note the failure is the window, not the GPU mode: hardware rendering with an
invisible window is as dead as software rendering.

The video E2E suites pass either way, and legitimately so — they run against
a still playground screen, and `screenrecord` is strictly variable-frame-rate,
so a still screen yields exactly one opening frame whether or not capture is
healthy (measured: 29,804 bytes / 1 frame headless vs 29,724 / 1 windowed,
near byte-identical). No assertion can separate the two without driving
sustained motion, and doing that from a test is itself enough to knock the
emulator off adb mid-suite. So if Android video capture ever looks empty,
check how the emulator was booted before suspecting the code.

E2E suites compile always but skip unless `SIM_USE_E2E=1` (iOS) / `SIM_USE_E2E_ANDROID=1` (Android) is set — `make test` never touches a device, which is why CI needs no simulator. The runners set those vars for you.

**Budget the time: a full green `make e2e-ios` run is ~15 minutes.** The iOS suites drive real HID gestures and wait on simulator animations/keyboard settling, so per-suite waits dominate — this is expected, not a hang. `make e2e` (both platforms) is ~20+ min. When you only touched one platform, run just that platform's target. The runners keep going past a failed suite and print a full pass/fail map at the end, so read the summary rather than assuming the first red aborted the rest.

`make e2e-matrix` validates the host-environment matrix: Xcode 26.x / 27.x × Device Hub closed at boot (`*-sim` legs — the Simulator.app workflow, legacy HID) or open at boot (`*-hub` legs — CoreDevice dtuhidd HID). One leg runs the full suite (default `x27-hub`; `ARGS="--full <leg>|all|none"`), the rest run the smoke tier (`scripts/test-runner.sh --smoke`: describe-ui, tap, type, scroll); legs whose Xcode is missing are skipped. The package builds once on the xcode-select toolchain — each leg only swaps the runtime Xcode via `SIM_USE_TEST_DEVELOPER_DIR` and boots a device matching its iOS generation, with dtuhidd/transport gates before and after the suites so a choreography failure cannot green-run the wrong combination. It quits Device Hub and shuts down every booted simulator, so never run it alongside other simulator work. Per-leg logs + evidence: `.build/e2e-matrix/<timestamp>/`.

Agent-facing behaviour (the bundled skill) has its own natural-language eval layer — see `e2e/agent-evals/README.md` and `docs/ai/003-e2e-confidence-suite/`.

### Verifying a change

After any non-trivial change, at minimum:

1. `make build` succeeds.
2. `make test` passes.
3. Spot-check the affected command on a live simulator (`describe-ui`, `tap @N`, `screenshot`).

## Module layout

Seven macOS SwiftPM targets plus a Linux executable; dependency graph flows in one direction.

| Target | Path | Depends on |
|---|---|---|
| `SimUseCore` | `Sources/SimUseCore/` | Foundation + ArgumentParser |
| `SimUseVideo` | `Sources/SimUseVideo/` | SimUseCore + AVFoundation/ImageIO |
| `iOSSimBackend` | `Sources/iOSSimBackend/` | SimUseCore + SimUseVideo + FB* XCFrameworks + AVFoundation |
| `iOSDeviceBackend` | `Sources/iOSDeviceBackend/` | SimUseCore + FBDeviceControl + FBControlCore |
| `HarmonyOSBackend` | `Sources/HarmonyOSBackend/` | SimUseCore + ArgumentParser |
| `AndroidBackend` | `Sources/AndroidBackend/` | SimUseCore + SimUseVideo + ArgumentParser |
| `SimUse` (executable) | `Sources/SimUse/` | SimUseCore + SimUseVideo + iOSSimBackend + iOSDeviceBackend + AndroidBackend + HarmonyOSBackend + FB* |
| `SimUseLinux` (executable, Linux only) | `Sources/SimUseLinux/` | SimUseCore + AndroidBackend |

On Linux, `Package.swift` declares only `SimUseCore`, `AndroidBackend` (without its three video-capture files) and `SimUseLinux` — see `docs/ai/008-linux-android-build/linux-guide.md`. Linux-only shims live in `Sources/SimUseCore/LinuxCompat.swift`; `swift build` / `swift test` run there directly.

`SimUseVideo` holds the platform-neutral host-side video plumbing (H.264 Annex B parsing, passthrough muxing, `AVAssetWriter` encoding, frame utilities) shared by the iOS and Android recording/streaming paths. It must stay FB*-free — anything that needs FBSimulatorControl belongs in `iOSSimBackend` (e.g. the `VideoFrameUtilities.captureScreenshotData` extension), anything adb-shaped in `AndroidBackend`.

### Verb dispatch

A verb (tap, swipe, type, ...) reaches four platform surfaces:

1. **Top-level** — `Sources/SimUse/Commands/<Verb>.swift`. Resolves the target via `PlatformRouter`, then forwards to the iOS or Android backend.
2. **`sim-use ios <verb>`** — `Sources/iOSSimBackend/Verbs/IOSSim<Verb>Command.swift`.
3. **`sim-use android <verb>`** — `Sources/AndroidBackend/Verbs/Android<Verb>Command.swift`.
4. **HarmonyOS** — commands under Sources/HarmonyOSBackend/Verbs, selected explicitly with --platform harmonyos at the top level.

Four verbs are iOS-only (`key`, `key-combo`, `key-sequence`, `batch`) — no top-level alias.

### Adding a new verb

- **Cross-platform**: write `IOSSim<Verb>Command` + `Android<Verb>Command`, plus a top-level forwarder in `Sources/SimUse/Commands/<Verb>.swift`. Register in `IOSSimCommand.swift`, `AndroidCommand.swift`, and `main.swift`.
- **iOS-only**: write `IOSSim<Verb>Command`, register in `IOSSimCommand` only. Use `HIDKeyCommandHelp.androidUnsupportedMessage` to reject Android UDIDs (see `IOSSimKeyCommand`).
- **Shared flags**: `@OptionGroup var udid: UDIDOptions` + `@OptionGroup var json: JSONOutputOptions`.

### Daemon

`SimUseExecutableCommand.run()` forwards UDID-scoped verbs to a per-UDID auto-spawned daemon (`Sources/SimUseCore/Daemon/`). Platform-agnostic — both iOS and Android verbs route through it. The `daemon` command itself lives in SimUseCore; each executable installs `Daemon.installPlatformHooks` (its root parser plus backend probes) at launch. A daemon is keyed by UDID alone, so each executable also installs `DaemonClient.connectionIdentityProvider`: the daemon reports the identity it started under in `_ping`, and the client's version gate restarts it when its own differs (Android: adb server + bridge host, via `BridgeConnection`). Each business request also carries the client's identity, and the daemon refuses a mismatch before it parses the request (`DaemonDispatch.connectionMismatchOutcome`), because a `_ping` that times out behind a busy daemon proves nothing. HarmonyOS verbs bypass the daemon because adb and hdc device IDs can collide. Key regression test: `Tests/DaemonCommandParserInjectionTests.swift`.

## Android development

The `bridge/` directory contains a Kotlin Android app (AccessibilityService + HTTP server) that the Swift CLI talks to over `adb forward`.

### Required tooling

| Tool | Version |
|---|---|
| Android SDK | `compileSdk=35`, `minSdk=30` |
| JDK | **17 -- 21** (Gradle 8.7 rejects 22+) |
| Gradle | 8.7 (wrapper in `bridge/gradlew`) |

`scripts/build-bridge.sh` auto-detects JDK and SDK paths. Run `scripts/build-bridge.sh --check` to verify the environment.

### Bridge wire spec

- `BuildConfig.PROTOCOL_VERSION` (Kotlin) and `BridgeClient.expectedProtocolVersion` (Swift) must match — bump together on breaking wire changes only.
- `versionCode` / `versionName` in `bridge/app/build.gradle.kts` — bump on any APK change.
- Endpoints: `bridge/.../server/ActionRouter.kt`; handlers in `.../handler/`.

### Bundling the APK

The APK is gitignored (`Sources/AndroidBackend/Resources/*.apk`). Run `scripts/build-bridge.sh` before `make build` so the binary includes Android support.

## HarmonyOS development

`HarmonyOSBackend` uses SDK-provided `hdc`, UITest, and uinput commands. It does not install a device-side bridge. The same hdc target interface covers DevEco emulators, USB devices, and TCP devices.

### Required tooling

- DevEco Studio or the HarmonyOS/OpenHarmony command-line SDK.
- `hdc` discoverable on `PATH`, through a standard SDK location, or via `SIM_USE_HDC=/absolute/path/to/hdc`.
- Developer options plus USB or wireless debugging enabled and authorized on the target.
- API 18+ for focused-field `uitest uiInput text`.

### Routing and caches

- Top-level verbs use `--platform harmonyos --device <connect-key>`.
- `sim-use harmonyos <verb>` auto-selects only when one hdc target is online.
- HarmonyOS outline caches use `harmonyos:<connect-key>` as the logical key.
- Keep HarmonyOS commands off the daemon until daemon identity is namespaced by platform.

### Verification

Run `swift test --filter HarmonyOSBackendTests` for parser, dumpLayout, renderer, selector, and fake-hdc command tests. With a target connected, spot-check read-only operations first:

```bash
sim-use harmonyos ping --device <connect-key>
sim-use ui --platform harmonyos --device <connect-key> --json
sim-use harmonyos screenshot --device <connect-key> --output /tmp/harmonyos-smoke.png
```

Interaction verbs should be exercised against a disposable fixture app, not a personal device screen.
