// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Output-path resolution shared by every file-producing verb (screenshots,
/// video recordings) across platform backends, so `--output` behaves the same
/// everywhere: trim and tilde-expand the supplied path, anchor relative paths
/// at the current directory, treat an existing directory as a destination
/// for a default-named file, create missing parent directories, and replace
/// an existing file.
///
/// Resolution and preparation are deliberately separate steps: `resolve`
/// never touches the filesystem beyond read-only stats, so a caller can
/// validate the resolved URL (e.g. enforce an extension) and reject it
/// without having destroyed an existing file at the target.
public enum OutputFilePath {
    /// Resolve the user-supplied `--output` argument into a concrete file
    /// URL. `defaultFilename` is consulted when no path is supplied or when
    /// the path names an existing directory; it is invoked at most once per
    /// call so timestamped names stay consistent. Performs no filesystem
    /// mutation — call `prepare(_:)` before writing to the returned URL.
    public static func resolve(output: String?, defaultFilename: () -> String) -> URL {
        let fileManager = FileManager.default
        var cachedDefault: String?
        func defaultName() -> String {
            if let cachedDefault { return cachedDefault }
            let name = defaultFilename()
            cachedDefault = name
            return name
        }

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = defaultName()
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return baseURL.appendingPathComponent(defaultName())
        }

        return baseURL
    }

    /// Destructive preparation of a resolved output URL: create missing
    /// parent directories and remove an existing file at the target so the
    /// subsequent write replaces it.
    public static func prepare(_ url: URL) throws {
        let fileManager = FileManager.default

        let directoryURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw CLIError(errorDescription: "Output path \(url.path) is a directory. Provide a file name or point to a different location.")
            }
            try fileManager.removeItem(at: url)
        }
    }

    /// Timestamp format shared by every screenshot default filename so paired
    /// screenshots from cross-platform sessions sort together.
    public static func screenshotTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
