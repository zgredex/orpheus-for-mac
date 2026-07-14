import Foundation

/// Shared syntax handling for portable M3U and M3U8 playlist references.
public enum QobuzM3UPlaylist {
    public static func paths(in contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return line
        }
    }

    public static func resolvedRelativePaths(
        in contents: String,
        playlistFolder: URL,
        libraryRoot: URL
    ) -> [String] {
        paths(in: contents).compactMap { path in
            guard !path.hasPrefix("/") else { return nil }
            let target = URL(fileURLWithPath: path, relativeTo: playlistFolder).standardizedFileURL
            return try? QobuzPathSafety.relativePath(of: target, in: libraryRoot)
        }
    }

    public static func referencesAnyLeafName(in contents: String, names: Set<String>) -> Bool {
        paths(in: contents).contains { names.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }
}
