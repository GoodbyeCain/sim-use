# Pitfalls and Recipes

Detailed solutions for common sim-use issues. The symptom index in SKILL.md points here.

## Label collision

**Symptom:** `tap --label 'X'` hits the wrong element, or returns `multipleMatches`.

**Why:** Multiple elements share the same accessibility label (e.g. a segmented control at the top and a tab bar at the bottom both say "Chat").

**Recipes:**
1. Add `--element-type RadioButton` (or whatever the outline shows) to narrow by type.
2. Add `--frame minY=0.7r` to restrict to a screen region. Use `r`-suffixed fractions for device-independent targeting.
3. Combine both: `--label 'Chat' --element-type RadioButton --frame minY=0.7r`.
4. If the element has a `#<id>` in the outline, use `tap '#<id>'` instead — it bypasses label matching entirely.

## Alias staleness

**Symptom:** `tap @N` fails or taps the wrong element after navigating to a new screen.

**Why:** `@N` aliases are cached from the last `ui` snapshot. Any screen change invalidates them.

**Rule:** Always re-run `sim-use ui` after any action that changes the screen (navigation, dismissing a dialog, scrolling). Then use the fresh `@N` values.

## HarmonyOS: text alias does not activate its control

**Symptom:** `tap @N` reports success on a HarmonyOS label such as a launcher app name, but the screen does not change.

**Why:** Older HarmonyOS alias caches stored the center of the non-clickable text leaf. Current builds preserve the text frame in `ui` output but cache the center of its nearest enabled clickable ancestor.

**Recipe:** Re-run `sim-use harmonyos ui` once to refresh the cache, then use the new `@N`. If the target has no clickable ancestor, use the actionable parent alias / `#<id>` shown by `ui`, or an explicit coordinate as a last resort.

## iOS: rotated simulator

**Symptom:** The `App:` header shows an orientation tag like `(landscape-right)` or `(portrait-upside-down)`, or a tap emits an `[i] Screen orientation could not be confirmed…` advisory.

**Why:** iOS accessibility frames rotate with the app while HID taps target the fixed portrait framebuffer. sim-use bridges the two automatically: every AX-derived tap (`@N`, `#<id>`, `--label` family, batch steps) self-calibrates the current orientation with 1–3 hit-test probes and transforms coordinates before dispatch.

**Recipes:**
1. Normally nothing to do — selectors work in any orientation, and outline/tap coordinates always read in UI space (what you see).
2. The calibration-fallback advisory means the mapping could not be verified (empty or symmetric screen) and portrait was assumed; re-run `ui` and retry, or use explicit `-x/-y`/`--point`.
3. A "snapshot was captured at WxH…" advisory means the device rotated after the last `ui`; re-run `ui` to refresh the `@N` table.
4. Explicit `-x/-y`/`--point` (and `--target-x/y`) are never transformed — they are device-native portrait coordinates by contract.
5. `batch` calibrates once per run. If a step rotates the device (or navigates to a screen that forces a different orientation), later selector steps may mis-target — split the flow into separate batches around the rotation.

## System layer detection

**Symptom:** `ui` output shows unexpected content — the `App:` header names a system process like `SpringBoard` (iOS), `com.android.systemui` (Android), or a different `bundleName/abilityName` component (HarmonyOS).

**Why:** A system alert, permission dialog, or share sheet is covering the app. The accessibility tree reflects whatever is on top.

**Recipe:**
1. Read the outline to identify the overlay (e.g. "Allow Paste", location permission, share sheet).
2. Dismiss it: tap the appropriate button (`Allow`, `Don't Allow`, `Cancel`), or `sim-use button home` to go home.
3. Re-run `ui` to confirm you're back in the app.

## iOS: paste drops text

**Symptom:** `sim-use paste 'text'` succeeds but the text field stays empty.

**Why:** The default path sends HID Cmd+V, which requires Simulator's hardware keyboard to be connected (Simulator > I/O > Keyboard > Connect Hardware Keyboard). In soft-keyboard-only mode, HID Cmd+V is silently dropped.

**Recipes:**
1. Check keyboard state: `sim-use keyboard-state`. If `soft`, use the menu path.
2. Menu path: `sim-use paste 'text' --via-menu --target-id <field-id>` — long-presses the field and taps the iOS edit menu "Paste" button.
3. If you control the simulator setup, enable hardware keyboard for all subsequent paste calls.

## iOS: U+FFFC icon placeholder

**Symptom:** An element's label in the outline contains a replacement character (often invisible or rendered as `￼`) before the actual text.

**Why:** iOS uses U+FFFC as an object-replacement character for inline icons. The accessibility label includes it.

**Recipe:** Use `--label-regex` with a pattern that skips the prefix: `--label-regex '.*Settings$'` or `--label-contains 'Settings'`.

## Android: paste denied

**Symptom:** `sim-use paste` succeeds but the field is empty, or the command errors.

**Why:** Android 10+ blocks background processes from setting the clipboard on some devices/configurations.

**Recipe:** Use `sim-use type 'text'` instead. On Android, `type` handles full unicode including CJK and emoji.

## Android: button back unpredictability

**Symptom:** `sim-use button back` navigates somewhere unexpected.

**Why:** Android's back behavior is app-defined. It might close a dialog, pop a nav stack, minimize the app, or do nothing.

**Recipe:** Always `ui` after `button back` to confirm where you ended up. If the result is wrong, use `tap` on a visible "Close" or "Cancel" button instead.

## HarmonyOS: target routes to Android

**Symptom:** A top-level command using an hdc connect-key reports an adb / Android error.

**Why:** adb and hdc identifiers are not disjoint. A USB serial can be an opaque alphanumeric string on either platform, and both transports can use `IP:port`.

**Recipe:** Add `--platform harmonyos --device <connect-key>` to top-level commands, or use `sim-use harmonyos <verb> --device <connect-key>`. When only one hdc target is online, the HarmonyOS namespace can omit `--device`.

## HarmonyOS: hdc works but UI/input does not

**Symptom:** `sim-use harmonyos ping` succeeds, but `ui`, `type`, or an input command fails.

**Why:** hdc transport availability is separate from UITest / uinput availability. The device must have debugging authorized, and focused-field `uitest uiInput text` requires API 18 or newer.

**Recipes:**
1. Run `sim-use harmonyos devices --all` and confirm the target is `Connected` or `Ready`.
2. Run `sim-use harmonyos ping --device <connect-key>` to isolate transport failures.
3. Verify developer options plus USB or wireless debugging authorization on the device.
4. For an unsupported command (`keyboard-state`, `record-video`, `app-state`, rotate), use a documented supported alternative rather than retrying.

## Tap lands but nothing happens

**Symptom:** `tap` reports success but the UI doesn't change.

**Why:** `ok:true` confirms dispatch, not an application post-condition. The element may not be interactive yet (animation in progress, view still loading), or it may need a longer hold.

**Recipes:**
1. Re-run `ui` or capture a screenshot before deciding whether the action succeeded.
2. For animation: add `--pre-delay 0.3` to wait before tapping, or `sleep 0.4` between commands.
3. For toggles/switches (shown as `CheckBox` in the outline), increase the hold with `--duration 0.1`. HarmonyOS already uses a 0.05s uinput down/up sequence for ordinary taps.
4. For elements that appear after navigation: use `--wait-timeout 3` to poll until the element exists.
