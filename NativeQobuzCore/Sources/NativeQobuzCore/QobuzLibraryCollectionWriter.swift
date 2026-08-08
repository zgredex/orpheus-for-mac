import Foundation

struct QobuzLibraryCollectionChange: Sendable {
    let manifest: QobuzLibraryManifest
    let playlistMembership: [QobuzPlaylistMembership]?
}

struct QobuzLibraryCollectionWriter: @unchecked Sendable {
    private let folderPlanner: QobuzPlaylistFolderPlanner
    private let retainedReader: QobuzRetainedTrackMembershipReader
    private let playlistResolver: QobuzPlaylistMembershipResolver

    init(folderPlanner: QobuzPlaylistFolderPlanner) {
        self.folderPlanner = folderPlanner
        let retainedReader = QobuzRetainedTrackMembershipReader()
        self.retainedReader = retainedReader
        playlistResolver = QobuzPlaylistMembershipResolver(retainedReader: retainedReader)
    }

    func prepare(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> QobuzLibraryCollectionChange {
        guard !outputs.isEmpty else {
            throw NativeQobuzError.emptyCollection(plan.title)
        }
        let records = try collectionRecords(plan: plan, outputs: outputs, fileSystem: fileSystem)
        var manifest = try QobuzLibraryManifestIO.load(in: fileSystem)
        let updatedIDs = Set(records.map(\.id))
        let existingByID = try recordsByID(manifest.collections)
        var playlistMembership: [QobuzPlaylistMembership]?
        let mergedRecords = try records.map { record in
            if record.kind == .playlist {
                let membership = try playlistResolver.resolve(
                    plan: plan,
                    outputs: outputs,
                    existing: existingByID[record.id],
                    fileSystem: fileSystem
                )
                playlistMembership = membership
                return record.replacingTrackPaths(membership.map(\.path.rawValue))
            }
            guard let existing = existingByID[record.id] else { return record }
            let retained = try retainedReader.memberships(from: existing, fileSystem: fileSystem)
            return record.replacingTrackPaths(
                QobuzLibraryTrackMembership.unique(retained.map(\.path.rawValue) + record.trackPaths)
            )
        }
        manifest.collections.removeAll { updatedIDs.contains($0.id) }
        manifest.collections.append(contentsOf: mergedRecords)
        manifest.collections.sort { $0.id < $1.id }
        try validate(
            manifest,
            newOutputPaths: Set(records.flatMap(\.trackPaths)),
            fileSystem: fileSystem
        )
        return QobuzLibraryCollectionChange(
            manifest: manifest,
            playlistMembership: playlistMembership
        )
    }

    func manifestMutation(
        _ change: QobuzLibraryCollectionChange,
        fileSystem: LibraryFileSystem
    ) throws -> LibraryFileTransactionMutation {
        let path = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        return try LibraryFileTransactionMutation.capture(
            path: path,
            finalState: .data(try QobuzLibraryManifestIO.encode(change.manifest)),
            in: fileSystem
        )
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
            let relativePath = try fileSystem.relativePath(for: output.audioURL)
            return [QobuzLibraryRecordFactory.track(
                qobuzID: id.rawValue,
                title: output.item.track.displayTitle,
                artist: output.item.track.performer?.name ?? output.item.album.artist.name,
                relativePath: relativePath.rawValue,
                artworkRelativePath: try existingArtworkRelativePath(
                    in: relativePath.parent,
                    fileSystem: fileSystem
                ),
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
                artworkRelativePath: try existingArtworkRelativePath(in: folderPath, fileSystem: fileSystem),
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
            artworkRelativePath: try existingArtworkRelativePath(in: folder, fileSystem: fileSystem),
            description: album.albumDescription,
            duration: album.duration
        )
    }

    private func existingArtworkRelativePath(
        in folder: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) throws -> String? {
        for filename in EmbeddedArtwork.externalFilenames {
            let path = try folder.appending(filename)
            guard let metadata = try fileSystem.metadata(at: path) else { continue }
            if metadata.kind == .symbolicLink {
                throw LibraryFileSystemError.symbolicLink(path.rawValue)
            }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            return path.rawValue
        }
        return nil
    }

    private func recordsByID(
        _ records: [QobuzLibraryCollectionRecord]
    ) throws -> [String: QobuzLibraryCollectionRecord] {
        var values: [String: QobuzLibraryCollectionRecord] = [:]
        for record in records {
            guard values.updateValue(record, forKey: record.id) == nil else {
                throw NativeQobuzError.invalidResponse(
                    "The Library manifest contains duplicate collection IDs."
                )
            }
        }
        return values
    }

    private func validate(
        _ manifest: QobuzLibraryManifest,
        newOutputPaths: Set<String>,
        fileSystem: LibraryFileSystem
    ) throws {
        let paths = Set(manifest.collections.flatMap(\.trackPaths))
        try QobuzArchiveSnapshotValidation.validateCollections(
            manifest.collections,
            physicalTrackPaths: paths
        )
        for value in newOutputPaths {
            let path = try LibraryRelativePath(value)
            guard try fileSystem.metadata(at: path)?.kind == .regularFile else {
                throw NativeQobuzError.invalidResponse(
                    "The Library manifest links a missing or non-regular audio file."
                )
            }
        }
    }
}
