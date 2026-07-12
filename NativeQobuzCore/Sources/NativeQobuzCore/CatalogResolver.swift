import Foundation

public struct QobuzCatalogResolver: Sendable {
    private let service: any QobuzCatalogService

    public init(service: any QobuzCatalogService) {
        self.service = service
    }

    public func resolve(_ request: QobuzRequest) async throws -> QobuzDownloadPlan {
        try Task.checkCancellation()
        switch request {
        case .track(let id):
            return try await resolveTrack(id: id, request: request)
        case .album(let id):
            let album = try await service.album(id: id)
            return try plan(album: album, request: request, collection: .album(id: album.id, title: album.displayTitle))
        case .playlist(let id):
            return try await resolvePlaylist(id: id, request: request)
        case .artist(let id):
            return try await resolveArtist(id: id, request: request)
        }
    }

    private func resolveTrack(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let track = try await service.track(id: id)
        guard let albumID = track.album?.id else {
            throw NativeQobuzError.missingAlbum(id)
        }
        let album = try await service.album(id: albumID)
        let resolved = QobuzResolvedTrack(
            track: track,
            album: album,
            collection: .track,
            position: 1,
            total: 1
        )
        return QobuzDownloadPlan(request: request, title: track.displayTitle, tracks: [resolved])
    }

    private func resolvePlaylist(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let playlist = try await service.playlist(id: id)
        guard !playlist.tracks.isEmpty else {
            throw NativeQobuzError.emptyCollection(playlist.name)
        }

        var albumCache: [QobuzID: QobuzAlbum] = [:]
        var resolved: [QobuzResolvedTrack] = []
        let collection = QobuzCollection.playlist(id: playlist.id, title: playlist.name)
        for (offset, track) in playlist.tracks.enumerated() {
            try Task.checkCancellation()
            guard let albumID = track.album?.id else {
                throw NativeQobuzError.missingAlbum(track.id)
            }
            let album: QobuzAlbum
            if let cached = albumCache[albumID] {
                album = cached
            } else {
                album = try await service.album(id: albumID)
                albumCache[albumID] = album
            }
            resolved.append(
                QobuzResolvedTrack(
                    track: track,
                    album: album,
                    collection: collection,
                    position: offset + 1,
                    total: playlist.tracks.count
                )
            )
        }
        return QobuzDownloadPlan(request: request, title: playlist.name, tracks: resolved)
    }

    private func resolveArtist(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let artist = try await service.artist(id: id)
        var seenAlbums = Set<QobuzID>()
        var albums: [QobuzAlbum] = []
        for summary in artist.albums where seenAlbums.insert(summary.id).inserted {
            try Task.checkCancellation()
            albums.append(try await service.album(id: summary.id))
        }

        let trackCount = albums.reduce(into: 0) { $0 += $1.tracks.count }
        guard trackCount > 0 else {
            throw NativeQobuzError.emptyCollection(artist.name)
        }

        let collection = QobuzCollection.artist(id: artist.id, name: artist.name)
        var position = 0
        var resolved: [QobuzResolvedTrack] = []
        resolved.reserveCapacity(trackCount)
        for album in albums {
            for track in album.tracks {
                position += 1
                resolved.append(
                    QobuzResolvedTrack(
                        track: track,
                        album: album,
                        collection: collection,
                        position: position,
                        total: trackCount
                    )
                )
            }
        }
        return QobuzDownloadPlan(request: request, title: artist.name, tracks: resolved)
    }

    private func plan(
        album: QobuzAlbum,
        request: QobuzRequest,
        collection: QobuzCollection
    ) throws -> QobuzDownloadPlan {
        guard !album.tracks.isEmpty else {
            throw NativeQobuzError.emptyCollection(album.displayTitle)
        }
        let total = album.tracks.count
        let tracks = album.tracks.enumerated().map { offset, track in
            QobuzResolvedTrack(
                track: track,
                album: album,
                collection: collection,
                position: offset + 1,
                total: total
            )
        }
        return QobuzDownloadPlan(request: request, title: album.displayTitle, tracks: tracks)
    }
}

public extension QobuzTrack {
    var displayTitle: String {
        var value = work.map { "\($0) - " } ?? ""
        value += title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let version, !version.isEmpty {
            value += " (\(version))"
        }
        return value
    }
}
