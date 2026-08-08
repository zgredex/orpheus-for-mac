import Foundation

struct QobuzLibraryPlaylistReplacement: Sendable {
    let path: LibraryRelativePath
    let contents: Data
}

struct QobuzLibraryPlaylistPrunePlanner {
    let fileSystem: LibraryFileSystem

    func replacements(
        originalCollections: [QobuzLibraryCollectionRecord],
        retainedCollections: [QobuzLibraryCollectionRecord],
        removing targetPaths: Set<String>
    ) throws -> [QobuzLibraryPlaylistReplacement] {
        var retainedByID: [String: QobuzLibraryCollectionRecord] = [:]
        for record in retainedCollections {
            guard retainedByID.updateValue(record, forKey: record.id) == nil else {
                throw NativeQobuzError.invalidResponse(
                    "The Library manifest contains duplicate collection IDs."
                )
            }
        }
        return try originalCollections.compactMap { original in
            guard original.kind == .playlist,
                  original.trackPaths.contains(where: targetPaths.contains),
                  let retained = retainedByID[original.id],
                  let playlistPath = try QobuzManagedLibraryAssetPolicy.managedPlaylistPath(
                    for: original
                  ),
                  let metadata = try fileSystem.metadata(at: playlistPath) else { return nil }
            try LibraryFileStateInspector(fileSystem: fileSystem).requireRegular(
                metadata,
                path: playlistPath
            )
            let contents = try fileSystem.readString(
                playlistPath,
                maximumBytes: LibraryArtifactLimits.playlist
            )
            let resolved = QobuzM3UPlaylist.resolvedEntries(
                in: contents,
                playlistFolder: fileSystem.displayURL(for: playlistPath.parent),
                libraryRoot: fileSystem.rootURL
            )
            guard resolved.map({ $0.relativePath }) == original.trackPaths else {
                throw NativeQobuzError.unavailable(
                    "The managed playlist changed after Library verification. Verify it again before pruning."
                )
            }
            let retainedEntries = resolved.filter { !targetPaths.contains($0.relativePath) }
            guard retainedEntries.map({ $0.relativePath }) == retained.trackPaths else {
                throw NativeQobuzError.fileSystem(
                    "The retained playlist projection does not match the Library manifest."
                )
            }
            return QobuzLibraryPlaylistReplacement(
                path: playlistPath,
                contents: Data(
                    QobuzM3UPlaylist.contents(for: retainedEntries.map { $0.entry }).utf8
                )
            )
        }
    }
}
