// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Shared JSON-size controls for every `describe-ui` surface.
///
/// The default JSON contract remains lossless for existing consumers.
/// Agent loops can opt into `--compact` when the rendered outline is
/// sufficient; alias caches are still populated from the full in-memory
/// outline before the result is compacted for encoding.
public struct DescribeUIOutputOptions: ParsableArguments {
    @Flag(
        name: .customLong("compact"),
        help: "Emit the rendered outline and screen/app metadata in --json mode. Removes the raw tree and clears structured entries/lists to reduce agent context usage."
    )
    public var compact = false

    public init() {}

    public func validate(jsonOutput: Bool) throws {
        if compact && !jsonOutput {
            throw ValidationError("--compact requires --json.")
        }
    }
}
