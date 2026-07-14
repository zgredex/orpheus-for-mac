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
        from manifestURL: URL,
        fileManager: FileManager = .default
    ) throws -> QobuzProvenanceManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return QobuzProvenanceManifest()
        }
        let value = try JSONDecoder().decode(
            QobuzProvenanceManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard value.version == QobuzProvenanceManifest.currentVersion else {
            throw NativeQobuzError.invalidResponse(
                "Unsupported provenance manifest version \(value.version)."
            )
        }
        return value
    }

    public static func load(
        in folder: URL,
        fileManager: FileManager = .default
    ) throws -> QobuzProvenanceManifest {
        try load(from: folder.appendingPathComponent(filename), fileManager: fileManager)
    }

    public static func encode(_ manifest: QobuzProvenanceManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }
}
