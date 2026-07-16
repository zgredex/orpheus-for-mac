import Foundation

/// Reader and writer for the GNU-style SHA-256 manifests stored beside audio.
public enum QobuzChecksumManifest {
    public static let filename = "checksums.sha256"

    public static func load(
        at path: LibraryRelativePath,
        in fileSystem: LibraryFileSystem
    ) throws -> [String: String] {
        guard try fileSystem.metadata(at: path) != nil else { return [:] }
        return parse(try fileSystem.readString(path))
    }

    static func load(at url: URL) throws -> [String: String] {
        let fileSystem = try LibraryFileSystem(
            rootURL: url.deletingLastPathComponent(),
            createIfMissing: false
        )
        return try load(at: LibraryRelativePath(url.lastPathComponent), in: fileSystem)
    }

    public static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard line.count > 64 else { continue }
            let hashEnd = line.index(line.startIndex, offsetBy: 64)
            let hash = line[..<hashEnd]
            guard hash.allSatisfy(\.isHexDigit) else { continue }
            let filename = line[hashEnd...].drop(while: { $0 == " " || $0 == "*" })
            guard !filename.isEmpty else { continue }
            result[String(filename)] = String(hash)
        }
        return result
    }

    public static func encode(_ entries: [String: String]) -> Data {
        let contents = entries.keys.sorted()
            .map { "\(entries[$0]!)  \($0)" }
            .joined(separator: "\n") + "\n"
        return Data(contents.utf8)
    }
}
