import Foundation

public struct QobuzLibraryCollectionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: QobuzArchiveKind
    public let qobuzID: String
    public let title: String
    public let subtitle: String
    public let relativePath: String
    public let trackPaths: [String]
    public let artworkRelativePath: String?
    public let collectionDescription: String?
    public let owner: String?
    public let createdAt: Int?
    public let updatedAt: Int?
    public let duration: Int?
    public let sourceTrackCount: Int?

    public init(
        id: String,
        kind: QobuzArchiveKind,
        qobuzID: String,
        title: String,
        subtitle: String,
        relativePath: String,
        trackPaths: [String],
        artworkRelativePath: String? = nil,
        collectionDescription: String? = nil,
        owner: String? = nil,
        createdAt: Int? = nil,
        updatedAt: Int? = nil,
        duration: Int? = nil,
        sourceTrackCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.qobuzID = qobuzID
        self.title = title
        self.subtitle = subtitle
        self.relativePath = relativePath
        self.trackPaths = trackPaths
        self.artworkRelativePath = artworkRelativePath
        self.collectionDescription = collectionDescription
        self.owner = owner
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.sourceTrackCount = sourceTrackCount
    }
}

public struct QobuzLibraryManifest: Codable, Equatable, Sendable {
    public let version: Int
    public var collections: [QobuzLibraryCollectionRecord]

    public init(version: Int = 1, collections: [QobuzLibraryCollectionRecord] = []) {
        self.version = version
        self.collections = collections
    }
}

public enum QobuzLibraryManifestIO {
    public static let filename = ".orpheus-library.json"

    public static func load(at root: URL, fileManager: FileManager = .default) throws -> QobuzLibraryManifest {
        let url = root.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else {
            qobuzLog.debug(
                "library.manifest",
                "Library manifest does not exist yet",
                metadata: ["manifestPath": url.path]
            )
            return QobuzLibraryManifest()
        }
        do {
            let value = try JSONDecoder().decode(QobuzLibraryManifest.self, from: Data(contentsOf: url))
            guard value.version == 1 else {
                throw NativeQobuzError.invalidResponse("Unsupported library manifest version \(value.version).")
            }
            qobuzLog.debug(
                "library.manifest",
                "Library manifest loaded",
                metadata: [
                    "manifestPath": url.path,
                    "collectionCount": String(value.collections.count),
                    "version": String(value.version)
                ]
            )
            return value
        } catch {
            qobuzLog.error(
                "library.manifest",
                "Library manifest could not be loaded",
                metadata: ["manifestPath": url.path],
                error: error
            )
            throw error
        }
    }

    public static func save(
        _ manifest: QobuzLibraryManifest,
        at root: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = root.appendingPathComponent(filename)
        let staging = root.appendingPathComponent(".\(filename).\(UUID().uuidString).partial")
        do {
            try encoder.encode(manifest).write(to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            qobuzLog.info(
                "library.manifest",
                "Library manifest saved",
                metadata: [
                    "manifestPath": destination.path,
                    "collectionCount": String(manifest.collections.count),
                    "version": String(manifest.version)
                ]
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            qobuzLog.error(
                "library.manifest",
                "Library manifest could not be saved",
                metadata: ["manifestPath": destination.path, "stagingPath": staging.path],
                error: error
            )
            throw NativeQobuzError.fileSystem("Could not update the library manifest: \(error.localizedDescription)")
        }
    }

    public static func relativePath(of url: URL, root: URL) throws -> String {
        do {
            return try QobuzPathSafety.relativePath(of: url, in: root)
        } catch {
            qobuzLog.error(
                "library.path",
                "Library asset resolved outside the download folder",
                metadata: ["assetPath": url.standardizedFileURL.path, "downloadRoot": root.standardizedFileURL.path]
            )
            throw error
        }
    }

}
