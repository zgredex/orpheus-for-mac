import Foundation

struct QobuzManagedLibraryAssets {
    let files: [LibraryRelativePath]
    let byteCount: Int64

    init(snapshot: QobuzArchiveSnapshot, fileSystem: LibraryFileSystem) throws {
        guard snapshot.rootPath == fileSystem.rootURL.path else {
            throw NativeQobuzError.fileSystem("The Library index does not belong to the selected folder.")
        }
        var candidates = try Set(snapshot.tracks.map { try LibraryRelativePath($0.relativePath) })
        let trackFolders = Set(candidates.map(\.parent))
        for folder in trackFolders {
            try Self.includeIfPresent(
                folder.appending(QobuzProvenanceManifestIO.filename),
                in: fileSystem,
                candidates: &candidates
            )
            try Self.includeIfPresent(
                folder.appending(QobuzChecksumManifest.filename),
                in: fileSystem,
                candidates: &candidates
            )
        }

        try Self.includeIfPresent(
            LibraryRelativePath(QobuzLibraryManifestIO.filename),
            in: fileSystem,
            candidates: &candidates
        )
        for collection in snapshot.collections {
            if let artwork = collection.artworkRelativePath {
                try Self.includeIfPresent(
                    LibraryRelativePath(artwork),
                    in: fileSystem,
                    candidates: &candidates
                )
            }
            let collectionPath = try QobuzManagedLibraryAssetPolicy.assetFolder(for: collection)
            guard try fileSystem.metadata(at: collectionPath)?.kind == .directory else { continue }
            for entry in try fileSystem.entries(in: collectionPath)
            where QobuzManagedLibraryAssetPolicy.isSidecar(entry.path, for: collection) {
                try Self.includeIfPresent(entry.path, in: fileSystem, candidates: &candidates)
            }
        }

        var total: Int64 = 0
        for path in candidates {
            guard let metadata = try fileSystem.metadata(at: path) else {
                throw LibraryFileSystemError.missing(path.rawValue)
            }
            if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            total += metadata.byteCount
        }
        files = candidates.sorted { $0.rawValue < $1.rawValue }
        byteCount = total
    }

    private static func includeIfPresent(
        _ path: LibraryRelativePath,
        in fileSystem: LibraryFileSystem,
        candidates: inout Set<LibraryRelativePath>
    ) throws {
        guard let metadata = try fileSystem.metadata(at: path) else { return }
        if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
        guard metadata.kind == .regularFile else {
            throw LibraryFileSystemError.notRegularFile(path.rawValue)
        }
        candidates.insert(path)
    }
}
