import Foundation

/// Reader and writer for the GNU-style SHA-256 manifests stored beside audio.
public enum QobuzChecksumManifest {
    public static let filename = "checksums.sha256"

    public static func load(
        at path: LibraryRelativePath,
        in fileSystem: LibraryFileSystem
    ) throws -> [String: String] {
        guard try fileSystem.metadata(at: path) != nil else { return [:] }
        return try decode(try fileSystem.readString(
            path,
            maximumBytes: LibraryArtifactLimits.checksumManifest
        ))
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
            guard let entry = parseLine(line) else { continue }
            result[entry.filename] = entry.hash
        }
        return result
    }

    private static func decode(_ contents: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let lines = contents.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            throw NativeQobuzError.invalidResponse("Checksum manifest is empty.")
        }
        for (index, line) in lines.enumerated() {
            guard let entry = parseLine(line), QobuzPathSafety.isSafeLeafName(entry.filename) else {
                throw NativeQobuzError.invalidResponse(
                    "Checksum manifest contains a malformed entry on line \(index + 1)."
                )
            }
            guard result.updateValue(entry.hash, forKey: entry.filename) == nil else {
                throw NativeQobuzError.invalidResponse(
                    "Checksum manifest contains duplicate entries for \(entry.filename)."
                )
            }
        }
        return result
    }

    private static func parseLine(_ line: Substring) -> (hash: String, filename: String)? {
        guard line.count > 66 else { return nil }
        let hashEnd = line.index(line.startIndex, offsetBy: 64)
        let markerEnd = line.index(hashEnd, offsetBy: 2)
        let hash = line[..<hashEnd]
        let marker = line[hashEnd..<markerEnd]
        let hashBytes = hash.utf8
        let isASCIIHex = hashBytes.count == 64 && hashBytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
        }
        guard isASCIIHex, marker == "  " || marker == " *" else { return nil }
        let filename = String(line[markerEnd...])
        return filename.isEmpty ? nil : (String(hash), filename)
    }

    public static func encode(_ entries: [String: String]) -> Data {
        let contents = entries.keys.sorted()
            .compactMap { filename in
                entries[filename].map { "\($0)  \(filename)" }
            }
            .joined(separator: "\n") + "\n"
        return Data(contents.utf8)
    }
}
