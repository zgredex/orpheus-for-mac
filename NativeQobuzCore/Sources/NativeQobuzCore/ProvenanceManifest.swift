import Foundation

/// The portable per-folder identity contract for downloaded audio files.
public struct QobuzProvenanceManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var files: [String: QobuzFileProvenance]

    public init(version: Int = currentVersion, files: [String: QobuzFileProvenance] = [:]) {
        self.version = version
        self.files = files
    }
}

public enum QobuzProvenanceManifestIO {
    public static let filename = ".orpheus-provenance.json"

    public static func load(
        from path: LibraryRelativePath,
        in fileSystem: LibraryFileSystem
    ) throws -> QobuzProvenanceManifest {
        guard try fileSystem.metadata(at: path) != nil else {
            return QobuzProvenanceManifest()
        }
        let value = try JSONDecoder().decode(
            QobuzProvenanceManifest.self,
            from: fileSystem.read(path, maximumBytes: LibraryArtifactLimits.provenanceManifest)
        )
        guard value.version == QobuzProvenanceManifest.currentVersion else {
            throw NativeQobuzError.invalidResponse(
                "Unsupported provenance manifest version \(value.version)."
            )
        }
        return value
    }

    static func load(from manifestURL: URL) throws -> QobuzProvenanceManifest {
        let fileSystem = try LibraryFileSystem(
            rootURL: manifestURL.deletingLastPathComponent(),
            createIfMissing: false
        )
        return try load(from: LibraryRelativePath(manifestURL.lastPathComponent), in: fileSystem)
    }

    public static func load(in folder: LibraryRelativePath, fileSystem: LibraryFileSystem) throws -> QobuzProvenanceManifest {
        try load(from: folder.appending(filename), in: fileSystem)
    }

    public static func encode(_ manifest: QobuzProvenanceManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }
}
