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
        guard fileManager.fileExists(atPath: url.path) else { return QobuzLibraryManifest() }
        let value = try JSONDecoder().decode(QobuzLibraryManifest.self, from: Data(contentsOf: url))
        guard value.version == 1 else {
            throw NativeQobuzError.invalidResponse("Unsupported library manifest version \(value.version).")
        }
        return value
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
        } catch {
            try? fileManager.removeItem(at: staging)
            throw NativeQobuzError.fileSystem("Could not update the library manifest: \(error.localizedDescription)")
        }
    }

    public static func relativePath(of url: URL, root: URL) throws -> String {
        let root = root.standardizedFileURL
        let value = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard value.path.hasPrefix(prefix) else {
            throw NativeQobuzError.fileSystem("A library asset is outside the download folder.")
        }
        return String(value.path.dropFirst(prefix.count))
    }

    public static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
