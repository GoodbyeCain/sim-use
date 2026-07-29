// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Flag validation shared by every surface of the cross-platform
/// `record-video` verb (top-level forwarder, `ios record-video`,
/// `android record-video`) so the contract cannot drift between
/// platforms.
public enum VideoRecordingOptions {
    public static func validate(fps: Int?, quality: Int, scale: Double) throws {
        if let fps {
            guard fps >= 1 && fps <= 60 else {
                throw ValidationError("FPS must be between 1 and 60")
            }
        }
        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }
        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }
}
