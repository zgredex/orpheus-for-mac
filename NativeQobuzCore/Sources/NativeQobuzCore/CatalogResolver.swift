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
        guard track.streamable else {
            throw NativeQobuzError.unavailable("This track is unavailable for the account region.")
        }
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
        let playableTracks = playlist.tracks.filter(\.streamable)
        guard !playableTracks.isEmpty else {
            throw NativeQobuzError.emptyCollection(playlist.name)
        }

        var albumCache: [QobuzID: QobuzAlbum] = [:]
        var resolved: [QobuzResolvedTrack] = []
        let collection = QobuzCollection.playlist(id: playlist.id, title: playlist.name)
        for (offset, track) in playableTracks.enumerated() {
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
                    total: playableTracks.count
                )
            )
        }
        return QobuzDownloadPlan(request: request, title: playlist.name, tracks: resolved)
    }

    private func resolveArtist(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let artist = try await service.artist(id: id)
        var seenAlbums = Set<QobuzID>()
        let summaries = artist.officialAlbums.filter { seenAlbums.insert($0.id).inserted }
        let albums = try await withThrowingTaskGroup(
            of: (Int, QobuzAlbum?).self,
            returning: [QobuzAlbum].self
        ) { group in
            let concurrency = min(6, summaries.count)
            var nextIndex = 0
            var ordered = Array<QobuzAlbum?>(repeating: nil, count: summaries.count)

            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                group.addTask { try await fetchArtistAlbum(at: index, summary: summaries[index]) }
            }

            while let (index, album) = try await group.next() {
                ordered[index] = album
                if nextIndex < summaries.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { try await fetchArtistAlbum(at: index, summary: summaries[index]) }
                }
            }
            return ordered.compactMap { $0 }
        }

        let trackCount = albums.reduce(into: 0) { $0 += $1.tracks.filter(\.streamable).count }
        guard trackCount > 0 else {
            throw NativeQobuzError.emptyCollection(artist.name)
        }

        let collection = QobuzCollection.artist(id: artist.id, name: artist.name)
        var position = 0
        var resolved: [QobuzResolvedTrack] = []
        resolved.reserveCapacity(trackCount)
        for album in albums {
            for track in album.tracks where track.streamable {
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

    private func fetchArtistAlbum(at index: Int, summary: QobuzAlbum) async throws -> (Int, QobuzAlbum?) {
        try Task.checkCancellation()
        do {
            let album = try await service.album(id: summary.id)
            return (index, album.tracks.contains(where: \.streamable) ? album : nil)
        } catch NativeQobuzError.unavailable(_) {
            return (index, nil)
        }
    }

    private func plan(
        album: QobuzAlbum,
        request: QobuzRequest,
        collection: QobuzCollection
    ) throws -> QobuzDownloadPlan {
        let playableTracks = album.tracks.filter(\.streamable)
        guard !playableTracks.isEmpty else {
            throw NativeQobuzError.emptyCollection(album.displayTitle)
        }
        let total = playableTracks.count
        let tracks = playableTracks.enumerated().map { offset, track in
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
