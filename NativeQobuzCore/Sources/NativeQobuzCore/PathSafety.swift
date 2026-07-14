import Foundation

/// Canonical lexical path rules for every portable archive and UI reveal path.
public enum QobuzPathSafety {
    public static func isContained(_ url: URL, in root: URL, allowingRoot: Bool = true) -> Bool {
        let root = root.standardizedFileURL
        let value = url.standardizedFileURL
        if value.path == root.path { return allowingRoot }
        return value.path.hasPrefix(directoryPrefix(for: root))
    }

    public static func relativePath(
        of url: URL,
        in root: URL,
        allowingRoot: Bool = false
    ) throws -> String {
        let root = root.standardizedFileURL
        let value = url.standardizedFileURL
        guard isContained(value, in: root, allowingRoot: allowingRoot) else {
            throw NativeQobuzError.fileSystem("A library asset is outside the download folder.")
        }
        if value.path == root.path { return "." }
        return String(value.path.dropFirst(directoryPrefix(for: root).count))
    }

    public static func relativePathOrLastComponent(
        of url: URL,
        in root: URL,
        allowingRoot: Bool = false
    ) -> String {
        (try? relativePath(of: url, in: root, allowingRoot: allowingRoot))
            ?? url.lastPathComponent
    }

    public static func containedURL(
        for relativePath: String,
        in root: URL,
        allowingRoot: Bool = false
    ) -> URL? {
        if relativePath == "." { return allowingRoot ? root.standardizedFileURL : nil }
        guard isSafeRelativePath(relativePath) else { return nil }
        let value = root.standardizedFileURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        return isContained(value, in: root, allowingRoot: allowingRoot) ? value : nil
    }

    public static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { isSafeLeafName(String($0)) }
    }

    public static func isSafeLeafName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
            && URL(fileURLWithPath: value).lastPathComponent == value
    }

    public static func directoryPath(of relativePath: String) -> String {
        let value = (relativePath as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    public static func lastComponent(of path: String, fallback: String) -> String {
        guard !path.isEmpty else { return fallback }
        let value = (path as NSString).lastPathComponent
        return value.isEmpty || value == "." ? fallback : value
    }

    public static func filenameStem(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func directoryPrefix(for root: URL) -> String {
        root.path.hasSuffix("/") ? root.path : root.path + "/"
    }
}
