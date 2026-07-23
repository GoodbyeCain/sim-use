# HarmonyOS Emulator and Device Support

## Status

Implemented as a first-party SwiftPM backend using the HarmonyOS / OpenHarmony SDK command-line tools. The implementation covers DevEco emulators, USB physical devices, and TCP-connected devices through the same hdc target model.

## Goals

- Preserve the existing observe → act → verify workflow and JSON envelope.
- Support both HarmonyOS emulators and physical devices without a custom device-side application.
- Keep platform-specific transport and normalization out of `SimUseCore`.
- Avoid ambiguous routing when adb and hdc expose identifiers with the same shape.
- Fail explicitly when no stable cross-device HarmonyOS primitive exists.

## Official tool contracts

The backend relies only on SDK-provided interfaces:

- `hdc list targets -v` discovers USB, TCP, and emulator targets and reports connection state.
- `hdc -t <connect-key> shell ...` selects one target.
- `uitest dumpLayout -p <path>` produces a `{attributes, children}` component tree.
- `uitest screenCap -p <path>` captures PNG screenshots.
- `uitest uiInput` provides click, focused text input, and Home / Back / Power key events.
- `uinput -T` provides touch down/up, timed movement, and up to three simultaneous linear contacts.

`uitest uiInput text` is available from API 18. UI description, screenshots, and input therefore remain subject to the tool availability of the target system image even when hdc transport itself is connected.

Primary references:

- [OpenHarmony hdc documentation](https://gitee.com/openharmony/docs/blob/master/en/application-dev/dfx/hdc.md)
- [OpenHarmony UITest usage guide](https://gitee.com/openharmony/docs/blob/master/en/application-dev/application-test/uitest-guidelines.md)
- [OpenHarmony uinput documentation](https://gitee.com/openharmony/docs/blob/master/en/application-dev/dfx/uinput.md)
- [ArkXTest source](https://gitee.com/openharmony/testfwk_arkxtest)

## Package architecture

```text
SimUse executable
  ├─ top-level forwarders + --platform harmonyos
  └─ sim-use harmonyos <verb>
          │
          ▼
HarmonyOSBackend
  ├─ Hdc                     process execution, discovery, target parsing
  ├─ HarmonyDeviceController transport-level operations
  ├─ HarmonyElementNode      dumpLayout decoding
  ├─ HarmonyOutlineRenderer  shared Outline normalization
  └─ HarmonyTargetResolver   alias / selector / coordinate resolution
          │
          ▼
SimUseCore
  Device, Outline, cache, selectors, JSON envelope, command protocol
```

The dependency direction remains one-way: `HarmonyOSBackend` depends on `SimUseCore`; the executable depends on all platform backends.

## Target resolution and routing

An hdc connect-key cannot be reliably classified by string shape. USB serials may look like Android serials, and TCP targets on both platforms use `IP:port`.

Consequently:

- Top-level HarmonyOS calls use `--platform harmonyos --device <connect-key>`.
- `SIM_USE_DEVICE` / `SIM_USE_UDID` can provide the device when `--platform harmonyos` is present.
- `sim-use harmonyos <verb>` resolves an omitted device only when exactly one hdc target is online.
- `sim-use devices --platform harmonyos` scopes discovery to hdc.

The legacy no-platform behavior remains unchanged: UUID-shaped IDs route to iOS Simulator, adb-shaped IDs route to Android, and unclassified IDs fall back to the iOS resolver.

## Daemon and cache isolation

HarmonyOS commands run in-process instead of using the existing per-device daemon. The daemon path and liveness tracker are keyed by an unqualified device ID and currently understand iOS / Android process semantics. Sending an hdc target through it could collide with an adb target carrying the same serial.

Outline caches are isolated with `harmonyos:<connect-key>` as the logical key. This preserves `tap @N` round-tripping without sharing an Android cache directory for the same raw identifier.

## Capability matrix

| Capability | HarmonyOS implementation | Notes |
|---|---|---|
| Devices / ping | hdc | Connected / Ready targets are usable |
| UI description | UITest `dumpLayout` | Normalized to shared `Outline`; raw dump included with `--json` |
| Tap / long-press | UITest click or timed uinput down/up | Alias, selector, and coordinate targeting |
| Swipe | uinput timed move | Duration is expressed in seconds at the CLI |
| Type / paste | UITest focused-field text | API 18+; no `paste --replace` or `--via-menu` |
| Buttons | UITest key events | Home, Back, Power/lock |
| Touch | uinput down/up/interval | Single contact |
| Multi-touch / pinch | uinput multi-contact move | Linear paths; two contacts exposed by sim-use |
| Screenshot | UITest `screenCap` | PNG copied with `hdc file recv` |
| Keyboard state | Unsupported | No stable UITest CLI visibility query |
| Record video | Unsupported | No stable streaming capture contract shared by emulator and device |
| App state / crash tracking | Unsupported | No daemon integration or stable process-list contract yet |
| Rotate gesture | Unsupported | Requires a curved multi-step contact path; uinput CLI exposes linear moves |

## UI normalization

UITest attributes remain stored as `[String: JSONValue]` because the platform adds fields over time. Typed accessors normalize the stable fields used by sim-use:

- `bounds` → `Outline.Frame`
- `type` → canonical role
- `description`, `text`, `hint`, `id` → label / value / identifiers
- `enabled`, `focused`, `selected`, `checked`, `scrollable`, `longClickable` → shared state tags
- `bundleName`, `abilityName` → app metadata

Whitespace is collapsed through `SelectorTextMatcher`, so text copied from the one-line outline round-trips through label selectors. Offscreen and invisible nodes are filtered by default. The raw UITest tree remains available in JSON for consumers needing platform-specific fields.

## Process execution and artifacts

`Hdc` resolves the binary in this order:

1. `SIM_USE_HDC`
2. common SDK environment roots
3. DevEco Studio application SDK paths
4. versioned `~/Library/Huawei/Sdk/openharmony` installations
5. `hdc` on `PATH`

stdout and stderr are drained concurrently to avoid pipe-buffer deadlocks. Commands have a bounded timeout. UI dumps and screenshots use UUID-named files under `/data/local/tmp`, are received into a unique host temporary directory, and are deleted from both sides on completion.

Focused text is passed as a single remote-shell-quoted argument. Single quotes are escaped with the standard shell-safe `'<prefix>'\''<suffix>'` form, preserving spaces and Unicode without host-shell interpolation.

## Verification

Automated coverage includes:

- verbose and empty hdc target-list parsing;
- remote argument forwarding and text quoting through a fake hdc executable;
- UITest dumpLayout JSON decoding and bounds normalization;
- outline roles, labels, identifiers, state tags, and offscreen filtering;
- selector whitespace parity, ambiguity handling, frame filtering, and platform routing;
- HarmonyOS `Device.isUsable` states and `--platform harmonyos` parsing.

Required repository checks are `make build` and `make test`. Device smoke verification should run `harmonyos ping`, `ui --json`, and `screenshot` against an available target. Interaction verbs should be tested on a disposable fixture app before release; read-only validation on a personal device is intentionally insufficient for claiming end-to-end gesture coverage.

## Follow-up work

- Add a DevEco emulator / physical-device Playground fixture and gated E2E runner.
- Add daemon namespacing by `(platform, deviceId)` before considering HarmonyOS daemon routing.
- Evaluate a stable process-list and foreground-app contract for `app-state` / crash awareness.
- Evaluate screen recording when a documented hdc API is available across supported system versions.
- Add curved trajectory support if uinput gains a stable multi-step path input format.
