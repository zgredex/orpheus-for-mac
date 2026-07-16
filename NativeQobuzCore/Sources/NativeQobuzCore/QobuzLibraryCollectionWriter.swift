import Foundation

struct QobuzLibraryCollectionWriter: @unchecked Sendable {
    private let folderPlanner: QobuzPlaylistFolderPlanner

    init(folderPlanner: QobuzPlaylistFolderPlanner) {
        self.folderPlanner = folderPlanner
    }

    func record(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> URL {
        guard !outputs.isEmpty else {
            throw NativeQobuzError.emptyCollection(plan.title)
        }
        let records = try collectionRecords(plan: plan, outputs: outputs, fileSystem: fileSystem)
        var manifest = try QobuzLibraryManifestIO.load(in: fileSystem)
        let updatedIDs = Set(records.map(\.id))
        manifest.collections.removeAll { updatedIDs.contains($0.id) }
        manifest.collections.append(contentsOf: records)
        manifest.collections.sort { $0.id < $1.id }
        try QobuzLibraryManifestIO.save(manifest, in: fileSystem)
        return fileSystem.displayURL(for: try LibraryRelativePath(QobuzLibraryManifestIO.filename))
    }

    private func collectionRecords(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> [QobuzLibraryCollectionRecord] {
        switch plan.request {
        case .album:
            return [try albumRecord(outputs: outputs, fileSystem: fileSystem)]
        case .artist, .label:
            var order: [QobuzID] = []
            var grouped: [QobuzID: [(item: QobuzResolvedTrack, audioURL: URL)]] = [:]
            for output in outputs {
                if grouped[output.item.album.id] == nil { order.append(output.item.album.id) }
                grouped[output.item.album.id, default: []].append(output)
            }
            return try order.compactMap { id in
                guard let values = grouped[id] else { return nil }
                return try albumRecord(outputs: values, fileSystem: fileSystem)
            }
        case .track(let id):
            let output = outputs[0]
            return [QobuzLibraryRecordFactory.track(
                qobuzID: id.rawValue,
                title: output.item.track.displayTitle,
                artist: output.item.track.performer?.name ?? output.item.album.artist.name,
                relativePath: try fileSystem.relativePath(for: output.audioURL).rawValue,
                duration: output.item.track.duration
            )]
        case .playlist(let id):
            let folder = folderPlanner.folder(title: plan.title, id: id, root: fileSystem.rootURL)
            let folderPath = try fileSystem.relativePath(for: folder)
            let playlist: QobuzPlaylist? = if case .playlist(let value)? = plan.source { value } else { nil }
            return [QobuzLibraryRecordFactory.playlist(
                qobuzID: id.rawValue,
                title: plan.title,
                owner: playlist?.owner?.name,
                relativePath: folderPath.rawValue,
                trackPaths: try outputs.map { try fileSystem.relativePath(for: $0.audioURL).rawValue },
                artworkRelativePath: existingArtworkRelativePath(in: folderPath, fileSystem: fileSystem),
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
        fileSystem: LibraryFileSystem
    ) throws -> QobuzLibraryCollectionRecord {
        guard let first = outputs.first else { throw NativeQobuzError.emptyCollection("Album") }
        let album = first.item.album
        let folder = try fileSystem.relativePath(for: first.audioURL).parent
        return QobuzLibraryRecordFactory.album(
            qobuzID: album.id.rawValue,
            title: album.displayTitle,
            artist: album.mainArtists.map(\.name).joined(separator: ", "),
            relativePath: folder.rawValue,
            trackPaths: try outputs.map { try fileSystem.relativePath(for: $0.audioURL).rawValue },
            artworkRelativePath: existingArtworkRelativePath(in: folder, fileSystem: fileSystem),
            description: album.albumDescription,
            duration: album.duration
        )
    }

    private func existingArtworkRelativePath(
        in folder: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) -> String? {
        for filename in EmbeddedArtwork.externalFilenames {
            guard let path = try? folder.appending(filename),
                  let metadata = try? fileSystem.metadata(at: path),
                  metadata.kind == .regularFile else { continue }
            return path.rawValue
        }
        return nil
    }
}
