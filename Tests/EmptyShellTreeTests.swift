// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// When a system document picker (or any remote-process presentation)
// owns the visible UI, the frontmost application's accessibility tree
// can come back as an empty shell — a bare AXApplication node with no
// frame and no children (issue #64). That shell is the trigger for the
// remote-content retry: it carries nothing for recovery or calibration
// to work from, so refetching with upstream's cross-process discovery
// is the only way to see the screen.
//
// `isEmptyShellTree` is the pure trigger decision: a payload is a
// shell iff no node in it carries a positive-area frame. Unrecognized
// shapes are NOT shells — failing closed keeps the retry (and its
// full-screen probe cost) off every path we don't understand.

@Suite("AccessibilityFetcher.isEmptyShellTree")
struct EmptyShellTreeTests {

    private func node(_ dict: [String: Any]) -> AnyObject { dict as AnyObject }
    private func nodes(_ array: [[String: Any]]) -> AnyObject { array as AnyObject }

    @Test("The 0.10.0-era shell — a bare AXApplication with no frame — is a shell")
    func bareApplicationIsShell() {
        let shell = nodes([["pid": 123, "role": "AXApplication"]])
        #expect(AccessibilityFetcher.isEmptyShellTree(shell))
    }

    @Test("The current-main shell — a full-screen-framed AXApplication with no children — is a shell")
    func framedChildlessApplicationIsShell() {
        // Captured live from a Safari + document-picker scene: the app
        // root DOES carry the screen-sized frame; only the content is
        // gone. The application container's own frame proves nothing
        // about visible content and must not veto the retry.
        let shell = nodes([[
            "AXFrame": "{{0, 0}, {402, 874}}",
            "AXLabel": "Safari浏览器",
            "children": [] as [[String: Any]],
            "enabled": true,
            "frame": ["height": 874, "width": 402, "x": 0, "y": 0],
            "pid": 5115,
            "role": "AXApplication",
            "role_description": "application",
            "type": "Application",
        ]])
        #expect(AccessibilityFetcher.isEmptyShellTree(shell))
    }

    @Test("An empty root array is a shell")
    func emptyArrayIsShell() {
        #expect(AccessibilityFetcher.isEmptyShellTree(nodes([])))
    }

    @Test("A framed non-application node is not a shell")
    func framedContentNodeIsNotShell() {
        let tree = nodes([[
            "role": "AXApplication",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            "children": [
                ["role": "AXWindow", "frame": ["x": 0, "y": 0, "width": 402, "height": 874]]
            ],
        ]])
        #expect(!AccessibilityFetcher.isEmptyShellTree(tree))
    }

    @Test("A frameless root whose child carries a frame is not a shell")
    func framedChildIsNotShell() {
        let tree = nodes([[
            "role": "AXApplication",
            "children": [
                ["role": "AXButton", "frame": ["x": 10, "y": 10, "width": 100, "height": 40]]
            ],
        ]])
        #expect(!AccessibilityFetcher.isEmptyShellTree(tree))
    }

    @Test("Zero-area frames do not rescue a shell")
    func zeroAreaFrameIsStillShell() {
        let tree = nodes([[
            "role": "AXApplication",
            "frame": ["x": 0, "y": 0, "width": 0, "height": 0],
            "children": [
                ["role": "AXGroup", "frame": ["x": 0, "y": 0, "width": 402, "height": 0]]
            ],
        ]])
        #expect(AccessibilityFetcher.isEmptyShellTree(tree))
    }

    @Test("A single-dictionary root follows the same rules")
    func singleDictionaryRoot() {
        #expect(AccessibilityFetcher.isEmptyShellTree(node(["pid": 5, "role": "AXApplication"])))
        #expect(!AccessibilityFetcher.isEmptyShellTree(node([
            "role": "AXButton",
            "frame": ["x": 0, "y": 0, "width": 100, "height": 100],
        ])))
    }

    @Test("Unrecognized payload shapes are not shells (fail closed)")
    func unrecognizedShapesAreNotShells() {
        #expect(!AccessibilityFetcher.isEmptyShellTree([1, 2, 3] as AnyObject))
        #expect(!AccessibilityFetcher.isEmptyShellTree("nonsense" as AnyObject))
    }
}
