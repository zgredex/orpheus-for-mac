import Foundation

/// Shared syntax handling for portable M3U and M3U8 playlist references.
public enum QobuzM3UPlaylist {
    struct Entry: Equatable, Sendable {
        let path: String
        let extendedInfo: String?
    }

    static func entries(in contents: String) -> [Entry] {
        var extendedInfo: String?
        var entries: [Entry] = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                extendedInfo = line
            } else if !line.hasPrefix("#") {
                entries.append(Entry(path: line, extendedInfo: extendedInfo))
                extendedInfo = nil
            }
        }
        return entries
    }

    static func contents(for entries: [Entry]) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            if let extendedInfo = entry.extendedInfo { lines.append(extendedInfo) }
            lines.append(entry.path)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func paths(in contents: String) -> [String] {
        entries(in: contents).map(\.path)
    }

    public static func resolvedRelativePaths(
        in contents: String,
        playlistFolder: URL,
        libraryRoot: URL
    ) -> [String] {
        resolvedEntries(
            in: contents,
            playlistFolder: playlistFolder,
            libraryRoot: libraryRoot
        ).map(\.relativePath)
    }

    public static func referencesAnyLeafName(in contents: String, names: Set<String>) -> Bool {
        paths(in: contents).contains { names.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    static func portableRelativePath(
        from folder: LibraryRelativePath,
        to target: LibraryRelativePath
    ) -> String {
        let folderParts = folder.components
        let targetParts = target.components
        var shared = 0
        while shared < folderParts.count,
              shared < targetParts.count,
              folderParts[shared] == targetParts[shared] { shared += 1 }
        let parents = Array(repeating: "..", count: folderParts.count - shared)
        return (parents + Array(targetParts.dropFirst(shared))).joined(separator: "/")
    }

    static func resolvedEntries(
        in contents: String,
        playlistFolder: URL,
        libraryRoot: URL
    ) -> [(entry: Entry, relativePath: String)] {
        entries(in: contents).compactMap { entry in
            guard !entry.path.hasPrefix("/") else { return nil }
            let target = URL(
                fileURLWithPath: entry.path,
                relativeTo: playlistFolder
            ).standardizedFileURL
            guard let relativePath = try? QobuzPathSafety.relativePath(
                of: target,
                in: libraryRoot
            ) else { return nil }
            return (entry, relativePath)
        }
    }
}
