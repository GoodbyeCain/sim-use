// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl

/// Legacy-shaped wrappers over the typed `FBAccessibilityElement` API.
///
/// Upstream idb replaced the dictionary-returning accessibility calls with an
/// opaque element handle plus an explicit serialize step. The serializer's
/// output shapes are unchanged (frontmost tree → array of dictionaries, point
/// query → single dictionary — "mirror the old SimulatorBridge implementation
/// for downstream compatibility" per upstream), so the whole downstream
/// pipeline (serialization, collapsed-children recovery, orientation
/// calibration) keeps consuming the same raw structures through these
/// wrappers.
extension FBSimulator {

    /// The frontmost application's accessibility tree, in the same shape the
    /// pre-Swiftification `accessibilityElements(withNestedFormat:)` returned:
    /// an array of dictionaries (a single root for the nested format).
    ///
    /// `includeRemoteContent` opts into upstream's coverage-grid discovery
    /// of elements owned by other processes (grid hit-testing over screen
    /// regions the frontmost tree does not cover). Off by default: on a
    /// healthy full-coverage tree it probes nothing, but on sparse (yet
    /// perfectly valid) trees it burns a grid of hit-test XPCs — callers
    /// enable it only when the plain fetch came back as an empty shell
    /// (issue #64).
    func legacyAccessibilityElements(nestedFormat: Bool, includeRemoteContent: Bool = false) async throws -> AnyObject {
        let element = try await accessibilityElementForFrontmostApplication()
        defer { element.close() }
        var options = FBAccessibilityRequestOptions(nestedFormat: nestedFormat)
        if includeRemoteContent {
            options.collectFrameCoverage = true
            options.remoteContentOptions = FBAccessibilityRemoteContentOptions()
        }
        let response = try element.serialize(with: options)
        return response.elements as AnyObject
    }

    /// The accessibility element at `point`, in the same single-dictionary
    /// shape the pre-Swiftification `accessibilityElement(at:nestedFormat:)`
    /// returned.
    func legacyAccessibilityElement(at point: CGPoint, nestedFormat: Bool) async throws -> AnyObject {
        let element = try await accessibilityElement(at: point)
        defer { element.close() }
        let response = try element.serialize(with: FBAccessibilityRequestOptions(nestedFormat: nestedFormat))
        return response.elements as AnyObject
    }
}
