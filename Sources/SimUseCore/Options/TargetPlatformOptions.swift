// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Explicit backend selection for top-level cross-platform commands.
/// Kept separate from `DeviceOptions` so platform-specific namespaces
/// (`sim-use ios`, `sim-use android`, `sim-use harmonyos`) do not expose a
/// contradictory `--platform` flag.
public struct TargetPlatformOptions: ParsableArguments {
    @Option(
        name: .customLong("platform"),
        help: "Target platform override: ios, android, or harmonyos. Required when a HarmonyOS device ID could also be an adb serial."
    )
    public var platform: Device.Platform?

    public init() {}
}
