import Foundation

struct QobuzPlaylistFolderPlanner: Sendable {
    private let outputPlanner: any QobuzOutputPlanning

    init(outputPlanner: any QobuzOutputPlanning) {
        self.outputPlanner = outputPlanner
    }

    func folder(title: String, id: QobuzID, root: URL) -> URL {
        root
            .appendingPathComponent("Playlists", isDirectory: true)
            .appendingPathComponent(folderName(title: title, id: id), isDirectory: true)
    }

    func folderName(title: String, id: QobuzID) -> String {
        QobuzFilenameComponent.make(
            stem: outputPlanner.sanitize(title),
            suffix: " [\(QobuzFilenameComponent.truncate(outputPlanner.sanitize(id.rawValue), toUTF8Bytes: 64))]"
        )
    }
}

struct QobuzPlaylistAssets: @unchecked Sendable {
    private let fetcher: any QobuzAssetFetching
    private let outputPlanner: any QobuzOutputPlanning
    private let folderPlanner: QobuzPlaylistFolderPlanner

    init(
        fetcher: any QobuzAssetFetching,
        outputPlanner: any QobuzOutputPlanning,
        folderPlanner: QobuzPlaylistFolderPlanner
    ) {
        self.fetcher = fetcher
        self.outputPlanner = outputPlanner
        self.folderPlanner = folderPlanner
    }

    func playlistMutation(
        plan: QobuzDownloadPlan,
        membership: [QobuzPlaylistMembership]?,
        fileSystem: LibraryFileSystem
    ) throws -> LibraryFileTransactionMutation? {
        guard case .playlist(let id) = plan.request,
              let membership,
              !membership.isEmpty else { return nil }
        let folder = folderPlanner.folder(title: plan.title, id: id, root: fileSystem.rootURL)
        let folderPath = try fileSystem.relativePath(for: folder)
        let destination = try folderPath.appending(
            QobuzManagedLibraryAssetPolicy.playlistFilename(
                title: plan.title,
                outputPlanner: outputPlanner
            )
        )
        let entries = membership.map { item in
            let fallback = QobuzPathSafety.filenameStem(of: item.path.rawValue)
            return QobuzM3UPlaylist.Entry(
                path: QobuzM3UPlaylist.portableRelativePath(from: folderPath, to: item.path),
                extendedInfo: "#EXTINF:\(item.presentation?.duration ?? -1), \(item.presentation?.label ?? fallback)"
            )
        }
        return try LibraryFileTransactionMutation.capture(
            path: destination,
            finalState: .data(Data(QobuzM3UPlaylist.contents(for: entries).utf8)),
            in: fileSystem
        )
    }

    func writeMetadata(plan: QobuzDownloadPlan, fileSystem: LibraryFileSystem) async throws -> [URL] {
        guard case .playlist(let id) = plan.request,
              case .playlist(let playlist)? = plan.source else { return [] }
        let folder = folderPlanner.folder(title: plan.title, id: id, root: fileSystem.rootURL)
        let folderPath = try fileSystem.relativePath(for: folder)
        var created: [URL] = []
        if let description = playlist.playlistDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            let destination = try folderPath.appending(
                QobuzManagedLibraryAssetPolicy.descriptionFilename
            )
            try fileSystem.writeAtomically(Data(description.utf8), to: destination)
            created.append(fileSystem.displayURL(for: destination))
        }
        if let source = playlist.artworkURL {
            if let existing = try existingArtwork(in: folderPath, fileSystem: fileSystem) {
                created.append(fileSystem.displayURL(for: existing))
            } else {
                let response = try await fetcher.fetch(
                    source,
                    maximumBytes: QobuzNetworkLimits.artwork
                )
                let artwork = try EmbeddedArtwork.validated(data: response.data, mimeType: response.mimeType)
                let destination = try folderPath.appending(artwork.externalFilename)
                try fileSystem.writeAtomically(artwork.data, to: destination)
                created.append(fileSystem.displayURL(for: destination))
            }
        }
        return created
    }

    private func existingArtwork(
        in folder: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) throws -> LibraryRelativePath? {
        for filename in EmbeddedArtwork.externalFilenames {
            let path = try folder.appending(filename)
            if try fileSystem.metadata(at: path)?.kind == .regularFile { return path }
        }
        return nil
    }
}
