import Foundation
@testable import NativeQobuzCore

struct PlaylistLibraryTestFixture {
    let root: URL
    let fileSystem: LibraryFileSystem
    let writer = QobuzCollectionAssetWriter()
    let playlistID = QobuzID("playlist")

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileSystem = try LibraryFileSystem(rootURL: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func plan(
        sourceTrackIDs: [String],
        playableTrackIDs: Set<String>? = nil,
        name: String = "Playlist"
    ) -> QobuzDownloadPlan {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Primary")
        let summary = QobuzAlbumSummary(
            id: QobuzID("album"),
            title: "Album",
            artist: artist
        )
        let sourceTracks = sourceTrackIDs.enumerated().map { offset, trackID in
            QobuzTrack(
                id: QobuzID(trackID),
                title: trackID.uppercased(),
                performer: artist,
                album: summary,
                duration: 120,
                trackNumber: offset + 1,
                mediaNumber: 1
            )
        }
        let playable = sourceTracks.filter { playableTrackIDs?.contains($0.id.rawValue) ?? true }
        let album = QobuzAlbum(
            id: summary.id,
            title: summary.title,
            artist: artist,
            tracks: playable,
            tracksCount: playable.count,
            mediaCount: 1
        )
        let items = playable.enumerated().map { offset, track in
            QobuzResolvedTrack(
                track: track,
                album: album,
                collection: .playlist(id: playlistID, title: name),
                position: offset + 1,
                total: playable.count
            )
        }
        let playlist = QobuzPlaylist(
            id: playlistID,
            name: name,
            tracks: sourceTracks,
            tracksCount: sourceTracks.count
        )
        return QobuzDownloadPlan(
            request: .playlist(playlistID),
            title: name,
            tracks: items,
            source: .playlist(playlist)
        )
    }

    func path(_ trackID: String, variant: String? = nil) throws -> LibraryRelativePath {
        let suffix = variant.map { "-\($0)" } ?? ""
        return try LibraryRelativePath("Primary/Album/\(trackID.uppercased())\(suffix).flac")
    }

    func seedManagedAudio(
        for item: QobuzResolvedTrack,
        at path: LibraryRelativePath
    ) throws {
        try fileSystem.writeAtomically(Data(path.rawValue.utf8), to: path)
        let fileInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/\(item.track.id.rawValue).flac")!,
            format: .lossless,
            bitDepth: 16,
            samplingRate: 44.1
        )
        try writer.recordProvenance(
            QobuzFileProvenance(
                item: item,
                delivery: try validatedTestDelivery(for: fileInfo),
                sha256: try MusicFileIntegrity.sha256(of: path, in: fileSystem),
                isLibraryManaged: true
            ),
            for: fileSystem.displayURL(for: path),
            fileSystem: fileSystem
        )
    }

    func seedManagedAudio(
        for plan: QobuzDownloadPlan,
        pathsByTrackID: [String: LibraryRelativePath]
    ) throws {
        var seeded = Set<LibraryRelativePath>()
        for item in plan.tracks {
            guard let path = pathsByTrackID[item.track.id.rawValue],
                  seeded.insert(path).inserted else { continue }
            try seedManagedAudio(for: item, at: path)
        }
    }

    func update(
        _ plan: QobuzDownloadPlan,
        pathsByTrackID: [String: LibraryRelativePath]
    ) async throws -> QobuzLibraryCollectionAssets {
        let outputs = try plan.tracks.map { item in
            guard let path = pathsByTrackID[item.track.id.rawValue] else {
                throw NativeQobuzError.unavailable(
                    "Missing test path for track \(item.track.id.rawValue)."
                )
            }
            return (item, fileSystem.displayURL(for: path))
        }
        return try await writer.updateLibraryCollections(
            plan: plan,
            outputs: outputs,
            fileSystem: fileSystem
        )
    }

    func playlistRecord() throws -> QobuzLibraryCollectionRecord {
        let record = try QobuzLibraryManifestIO.load(in: fileSystem).collections.first {
            $0.id == "playlist|\(playlistID.rawValue)"
        }
        guard let record else {
            throw NativeQobuzError.unavailable("The playlist test record is missing.")
        }
        return record
    }

    func resolvedM3UPaths(at url: URL) throws -> [String] {
        QobuzM3UPlaylist.resolvedRelativePaths(
            in: try String(contentsOf: url, encoding: .utf8),
            playlistFolder: url.deletingLastPathComponent(),
            libraryRoot: root
        )
    }

    func trackIDs(for paths: [String]) throws -> [String] {
        let store = QobuzProvenanceStore()
        return try paths.map { value in
            let path = try LibraryRelativePath(value)
            let provenance = try store.provenance(
                for: fileSystem.displayURL(for: path),
                fileSystem: fileSystem
            )
            guard let provenance else {
                throw NativeQobuzError.unavailable("Missing test provenance for \(value).")
            }
            return provenance.qobuzTrackID
        }
    }
}
