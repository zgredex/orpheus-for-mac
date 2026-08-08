import Foundation

enum QobuzManagedLibraryAssetPolicy {
    static let descriptionFilename = "description.txt"
    static let bookletFilename = "Booklet.pdf"
    static let preferredPlaylistExtension = "m3u"
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    static func playlistFilename(
        title: String,
        outputPlanner: any QobuzOutputPlanning
    ) -> String {
        "\(outputPlanner.sanitize(title)).\(preferredPlaylistExtension)"
    }

    static func managedPlaylistPath(
        for collection: QobuzLibraryCollectionRecord
    ) throws -> LibraryRelativePath? {
        guard collection.kind == .playlist,
              isStandardPlaylistFolder(collection) else { return nil }
        return try assetFolder(for: collection).appending(
            playlistFilename(
                title: collection.title,
                outputPlanner: StandardQobuzOutputPlanner()
            )
        )
    }

    static func isSidecar(
        _ path: LibraryRelativePath,
        for collection: QobuzLibraryCollectionRecord
    ) -> Bool {
        guard let folder = try? assetFolder(for: collection),
              path.parent == folder,
              let name = path.lastComponent else { return false }
        if collection.artworkRelativePath == path.rawValue { return true }
        if collection.kind == .playlist, !isStandardPlaylistFolder(collection) { return false }

        let lowercased = name.lowercased()
        switch collection.kind {
        case .album:
            return lowercased == descriptionFilename.lowercased()
                || lowercased == bookletFilename.lowercased()
        case .playlist:
            return lowercased == descriptionFilename.lowercased()
                || (try? managedPlaylistPath(for: collection)) == path
        case .track:
            return lowercased == bookletFilename.lowercased()
        case .unclassified:
            return false
        }
    }

    static func assetFolder(
        for collection: QobuzLibraryCollectionRecord
    ) throws -> LibraryRelativePath {
        let path = try LibraryRelativePath(collection.relativePath)
        return collection.kind == .track ? path.parent : path
    }

    private static func isStandardPlaylistFolder(
        _ collection: QobuzLibraryCollectionRecord
    ) -> Bool {
        let folderPlanner = QobuzPlaylistFolderPlanner(outputPlanner: StandardQobuzOutputPlanner())
        let folderName = folderPlanner.folderName(
            title: collection.title,
            id: QobuzID(collection.qobuzID)
        )
        return collection.relativePath == "Playlists/\(folderName)"
    }
}
