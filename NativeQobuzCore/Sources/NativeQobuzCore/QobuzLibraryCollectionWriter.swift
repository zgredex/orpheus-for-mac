import Foundation

struct QobuzLibraryCollectionWriter: @unchecked Sendable {
    private let folderPlanner: QobuzPlaylistFolderPlanner
    private let fileManager: FileManager

    init(folderPlanner: QobuzPlaylistFolderPlanner, fileManager: FileManager) {
        self.folderPlanner = folderPlanner
        self.fileManager = fileManager
    }

    func record(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        downloadRoot: URL
    ) throws -> URL {
        guard !outputs.isEmpty else {
            throw NativeQobuzError.emptyCollection(plan.title)
        }
        let records = try collectionRecords(plan: plan, outputs: outputs, root: downloadRoot)
        var manifest = try QobuzLibraryManifestIO.load(at: downloadRoot, fileManager: fileManager)
        let updatedIDs = Set(records.map(\.id))
        manifest.collections.removeAll { updatedIDs.contains($0.id) }
        manifest.collections.append(contentsOf: records)
        manifest.collections.sort { $0.id < $1.id }
        try QobuzLibraryManifestIO.save(manifest, at: downloadRoot, fileManager: fileManager)
        return downloadRoot.appendingPathComponent(QobuzLibraryManifestIO.filename)
    }

    private func collectionRecords(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        root: URL
    ) throws -> [QobuzLibraryCollectionRecord] {
        switch plan.request {
        case .album:
            return [try albumRecord(outputs: outputs, root: root)]
        case .artist, .label:
            var order: [QobuzID] = []
            var grouped: [QobuzID: [(item: QobuzResolvedTrack, audioURL: URL)]] = [:]
            for output in outputs {
                if grouped[output.item.album.id] == nil { order.append(output.item.album.id) }
                grouped[output.item.album.id, default: []].append(output)
            }
            return try order.compactMap { id in
                guard let values = grouped[id] else { return nil }
                return try albumRecord(outputs: values, root: root)
            }
        case .track(let id):
            let output = outputs[0]
            return [QobuzLibraryRecordFactory.track(
                qobuzID: id.rawValue,
                title: output.item.track.displayTitle,
                artist: output.item.track.performer?.name ?? output.item.album.artist.name,
                relativePath: try QobuzLibraryManifestIO.relativePath(of: output.audioURL, root: root),
                duration: output.item.track.duration
            )]
        case .playlist(let id):
            let folder = folderPlanner.folder(title: plan.title, id: id, root: root)
            let playlist: QobuzPlaylist? = if case .playlist(let value)? = plan.source { value } else { nil }
            return [QobuzLibraryRecordFactory.playlist(
                qobuzID: id.rawValue,
                title: plan.title,
                owner: playlist?.owner?.name,
                relativePath: try QobuzLibraryManifestIO.relativePath(of: folder, root: root),
                trackPaths: try outputs.map { try QobuzLibraryManifestIO.relativePath(of: $0.audioURL, root: root) },
                artworkRelativePath: existingArtworkRelativePath(in: folder, root: root),
                description: playlist?.playlistDescription,
                createdAt: playlist?.createdAt,
                updatedAt: playlist?.updatedAt,
                duration: playlist?.duration,
                sourceTrackCount: playlist?.tracksCount ?? playlist?.tracksTotal
            )]
        }
    }

    private func albumRecord(
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        root: URL
    ) throws -> QobuzLibraryCollectionRecord {
        guard let first = outputs.first else { throw NativeQobuzError.emptyCollection("Album") }
        let album = first.item.album
        let folder = first.audioURL.deletingLastPathComponent()
        return QobuzLibraryRecordFactory.album(
            qobuzID: album.id.rawValue,
            title: album.displayTitle,
            artist: album.mainArtists.map(\.name).joined(separator: ", "),
            relativePath: try QobuzLibraryManifestIO.relativePath(of: folder, root: root),
            trackPaths: try outputs.map { try QobuzLibraryManifestIO.relativePath(of: $0.audioURL, root: root) },
            artworkRelativePath: existingArtworkRelativePath(in: folder, root: root),
            description: album.albumDescription,
            duration: album.duration
        )
    }

    private func existingArtworkRelativePath(in folder: URL, root: URL) -> String? {
        EmbeddedArtwork.existingExternalFile(in: folder, fileManager: fileManager)
            .flatMap { try? QobuzLibraryManifestIO.relativePath(of: $0, root: root) }
    }
}
