import Foundation
import NativeQobuzCore

enum NativePersistentArtifact: String, Sendable {
    case settings = "settings.json"
    case archiveIndex = "archive-index.json"
    case credentials = "credentials.json"
    case session = "download-session.json"

    var maximumBytes: Int {
        switch self {
        case .settings, .credentials: 256 * 1_024
        case .session: 64 * 1_024 * 1_024
        case .archiveIndex: 256 * 1_024 * 1_024
        }
    }
}

struct NativeApplicationSupportFileStore: Sendable {
    let rootURL: URL

    func read(_ artifact: NativePersistentArtifact) throws -> Data? {
        let fileSystem: LibraryFileSystem
        do {
            fileSystem = try LibraryFileSystem(rootURL: rootURL, createIfMissing: false)
        } catch LibraryFileSystemError.missing {
            return nil
        }
        let path = try LibraryRelativePath(artifact.rawValue)
        guard try fileSystem.metadata(at: path) != nil else { return nil }
        return try fileSystem.read(path, maximumBytes: artifact.maximumBytes)
    }

    func write(_ data: Data, to artifact: NativePersistentArtifact) throws {
        guard data.count <= artifact.maximumBytes else {
            throw LibraryFileSystemError.tooLarge(
                path: artifact.rawValue,
                maximumBytes: artifact.maximumBytes,
                actualBytes: Int64(data.count)
            )
        }
        let fileSystem = try LibraryFileSystem(rootURL: rootURL)
        try fileSystem.setRootPermissions(0o700)
        try fileSystem.writeAtomically(data, to: LibraryRelativePath(artifact.rawValue))
    }

    func quarantine(
        _ artifact: NativePersistentArtifact,
        rejectedPrefix: String
    ) throws -> URL {
        let fileSystem = try LibraryFileSystem(rootURL: rootURL, createIfMissing: false)
        let rejectedName = "\(rejectedPrefix)-\(UUID().uuidString).json"
        try fileSystem.moveItem(
            at: LibraryRelativePath(artifact.rawValue),
            to: LibraryRelativePath(rejectedName)
        )
        return rootURL.appendingPathComponent(rejectedName)
    }
}
