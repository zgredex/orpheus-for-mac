import Foundation

struct LibraryFileStateInspector {
    let fileSystem: LibraryFileSystem

    func expectedState(at path: LibraryRelativePath) throws -> LibraryFileExpectedState {
        guard let metadata = try fileSystem.metadata(at: path) else { return .absent }
        try requireRegular(metadata, path: path)
        return .regularFile(sha256: try digest(at: path))
    }

    func requireRegular(_ metadata: LibraryFileMetadata, path: LibraryRelativePath) throws {
        if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
        guard metadata.kind == .regularFile else {
            throw LibraryFileSystemError.notRegularFile(path.rawValue)
        }
    }

    func requireDigest(
        _ expected: String,
        at path: LibraryRelativePath,
        changedMessage: String
    ) throws {
        guard try digest(at: path) == expected else {
            throw NativeQobuzError.fileSystem(changedMessage)
        }
    }

    func digest(at path: LibraryRelativePath) throws -> String {
        try MusicFileIntegrity.sha256(of: path, in: fileSystem)
    }
}
