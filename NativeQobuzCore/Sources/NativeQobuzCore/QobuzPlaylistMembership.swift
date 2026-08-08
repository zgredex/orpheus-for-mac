import Foundation

struct QobuzPlaylistTrackPresentation: Equatable, Sendable {
    let duration: Int
    let label: String
}

struct QobuzPlaylistMembership: Equatable, Sendable {
    let path: LibraryRelativePath
    let qobuzTrackID: String
    let presentation: QobuzPlaylistTrackPresentation?

    func presenting(_ track: QobuzTrack, fallbackArtist: String? = nil) -> Self {
        let artist = track.performer?.name
            ?? track.album?.artist?.name
            ?? fallbackArtist
            ?? "Unknown Artist"
        return Self(
            path: path,
            qobuzTrackID: qobuzTrackID,
            presentation: QobuzPlaylistTrackPresentation(
                duration: track.duration ?? -1,
                label: "\(artist) - \(track.displayTitle)"
            )
        )
    }
}

struct QobuzRetainedTrackMembershipReader: @unchecked Sendable {
    private let provenanceStore = QobuzProvenanceStore()

    func memberships(
        from record: QobuzLibraryCollectionRecord,
        fileSystem: LibraryFileSystem
    ) throws -> [QobuzPlaylistMembership] {
        var acceptedTrackIDs: [LibraryRelativePath: String] = [:]
        var rejectedPaths = Set<LibraryRelativePath>()
        var memberships: [QobuzPlaylistMembership] = []

        for value in record.trackPaths {
            let path = try LibraryRelativePath(value)
            if let trackID = acceptedTrackIDs[path] {
                memberships.append(membership(path: path, trackID: trackID))
                continue
            }
            if rejectedPaths.contains(path) { continue }

            guard let metadata = try fileSystem.metadata(at: path) else {
                rejectedPaths.insert(path)
                continue
            }
            if metadata.kind == .symbolicLink {
                throw LibraryFileSystemError.symbolicLink(path.rawValue)
            }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            guard let provenance = try provenanceStore.provenance(
                for: fileSystem.displayURL(for: path),
                fileSystem: fileSystem
            ), provenance.isLibraryManaged, belongs(provenance, to: record) else {
                rejectedPaths.insert(path)
                continue
            }
            acceptedTrackIDs[path] = provenance.qobuzTrackID
            memberships.append(membership(path: path, trackID: provenance.qobuzTrackID))
        }
        return memberships
    }

    private func membership(path: LibraryRelativePath, trackID: String) -> QobuzPlaylistMembership {
        QobuzPlaylistMembership(path: path, qobuzTrackID: trackID, presentation: nil)
    }

    private func belongs(
        _ provenance: QobuzFileProvenance,
        to record: QobuzLibraryCollectionRecord
    ) -> Bool {
        switch record.kind {
        case .album: provenance.qobuzAlbumID == record.qobuzID
        case .track: provenance.qobuzTrackID == record.qobuzID
        case .playlist: true
        case .unclassified: false
        }
    }
}

struct QobuzPlaylistMembershipResolver: Sendable {
    private let retainedReader: QobuzRetainedTrackMembershipReader

    init(retainedReader: QobuzRetainedTrackMembershipReader) {
        self.retainedReader = retainedReader
    }

    func resolve(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        existing: QobuzLibraryCollectionRecord?,
        fileSystem: LibraryFileSystem
    ) throws -> [QobuzPlaylistMembership] {
        let fresh = try outputs.map { output in
            QobuzPlaylistMembership(
                path: try fileSystem.relativePath(for: output.audioURL),
                qobuzTrackID: output.item.track.id.rawValue,
                presentation: nil
            ).presenting(output.item.track, fallbackArtist: output.item.album.artist.name)
        }
        let retained: [QobuzPlaylistMembership]
        if plan.selectionScope == .subset, let existing {
            let selectedTrackIDs = Set(fresh.map(\.qobuzTrackID))
            retained = try retainedReader.memberships(from: existing, fileSystem: fileSystem)
                .filter { !selectedTrackIDs.contains($0.qobuzTrackID) }
        } else {
            retained = []
        }
        return order(
            sourceTracks: sourceTracks(for: plan),
            retained: retained,
            fresh: fresh
        )
    }

    private func sourceTracks(for plan: QobuzDownloadPlan) -> [QobuzTrack] {
        if case .playlist(let playlist)? = plan.source { return playlist.tracks }
        return plan.tracks.map(\.track)
    }

    private func order(
        sourceTracks: [QobuzTrack],
        retained: [QobuzPlaylistMembership],
        fresh: [QobuzPlaylistMembership]
    ) -> [QobuzPlaylistMembership] {
        var retainedPool = MembershipPool(retained)
        var freshPool = MembershipPool(fresh)
        var ordered: [QobuzPlaylistMembership] = []

        for track in sourceTracks {
            if let membership = freshPool.pop(trackID: track.id.rawValue)
                ?? retainedPool.pop(trackID: track.id.rawValue) {
                ordered.append(membership.presenting(track))
            }
        }
        ordered.append(contentsOf: retainedPool.unused)
        ordered.append(contentsOf: freshPool.unused)
        return ordered
    }
}

private struct MembershipPool {
    private let values: [QobuzPlaylistMembership]
    private var indicesByTrackID: [String: [Int]]
    private var used = Set<Int>()

    init(_ values: [QobuzPlaylistMembership]) {
        self.values = values
        indicesByTrackID = Dictionary(grouping: values.indices, by: { values[$0].qobuzTrackID })
            .mapValues { Array($0.reversed()) }
    }

    mutating func pop(trackID: String) -> QobuzPlaylistMembership? {
        guard var indices = indicesByTrackID[trackID], let index = indices.popLast() else { return nil }
        indicesByTrackID[trackID] = indices
        used.insert(index)
        return values[index]
    }

    var unused: [QobuzPlaylistMembership] {
        values.indices.compactMap { used.contains($0) ? nil : values[$0] }
    }
}
