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

    public static func load(in fileSystem: LibraryFileSystem) throws -> QobuzLibraryManifest {
        let path = try LibraryRelativePath(filename)
        guard try fileSystem.metadata(at: path) != nil else {
            qobuzLog.debug(
                "library.manifest",
                "Library manifest does not exist yet",
                metadata: ["manifestPath": fileSystem.displayURL(for: path).path]
            )
            return QobuzLibraryManifest()
        }
        do {
            let value = try JSONDecoder().decode(QobuzLibraryManifest.self, from: fileSystem.read(path))
            guard value.version == 1 else {
                throw NativeQobuzError.invalidResponse("Unsupported library manifest version \(value.version).")
            }
            qobuzLog.debug(
                "library.manifest",
                "Library manifest loaded",
                metadata: [
                    "manifestPath": fileSystem.displayURL(for: path).path,
                    "collectionCount": String(value.collections.count),
                    "version": String(value.version)
                ]
            )
            return value
        } catch {
            qobuzLog.error(
                "library.manifest",
                "Library manifest could not be loaded",
                metadata: ["manifestPath": fileSystem.displayURL(for: path).path],
                error: error
            )
            throw error
        }
    }

    public static func load(at root: URL) throws -> QobuzLibraryManifest {
        do {
            return try load(in: LibraryFileSystem(rootURL: root, createIfMissing: false))
        } catch LibraryFileSystemError.missing {
            return QobuzLibraryManifest()
        }
    }

    public static func save(
        _ manifest: QobuzLibraryManifest,
        in fileSystem: LibraryFileSystem
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = try LibraryRelativePath(filename)
        do {
            try fileSystem.writeAtomically(encoder.encode(manifest), to: destination)
            qobuzLog.info(
                "library.manifest",
                "Library manifest saved",
                metadata: [
                    "manifestPath": fileSystem.displayURL(for: destination).path,
                    "collectionCount": String(manifest.collections.count),
                    "version": String(manifest.version)
                ]
            )
        } catch {
            qobuzLog.error(
                "library.manifest",
                "Library manifest could not be saved",
                metadata: ["manifestPath": fileSystem.displayURL(for: destination).path],
                error: error
            )
            throw NativeQobuzError.fileSystem("Could not update the library manifest: \(error.localizedDescription)")
        }
    }

    public static func save(_ manifest: QobuzLibraryManifest, at root: URL) throws {
        try save(manifest, in: LibraryFileSystem(rootURL: root))
    }

    public static func relativePath(of url: URL, fileSystem: LibraryFileSystem) throws -> String {
        do {
            return try fileSystem.relativePath(for: url).rawValue
        } catch {
            qobuzLog.error(
                "library.path",
                "Library asset resolved outside the download folder",
                metadata: ["assetPath": url.standardizedFileURL.path, "downloadRoot": fileSystem.rootURL.path]
            )
            throw error
        }
    }


    public static func relativePath(of url: URL, root: URL) throws -> String {
        try QobuzPathSafety.relativePath(of: url, in: root)
    }

}
