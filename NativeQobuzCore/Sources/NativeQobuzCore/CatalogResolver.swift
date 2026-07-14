import Foundation

public struct QobuzCatalogResolver: Sendable {
    private let service: any QobuzCatalogService

    public init(service: any QobuzCatalogService) {
        self.service = service
    }

    public func resolve(_ request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let metadata = ["requestKind": request.kindName, "qobuzID": request.id.rawValue]
        return try await QobuzLogScope.withValue(metadata) {
            let started = Date()
            qobuzLog.info("catalog.resolve", "Catalog resolution started")
            do {
                try Task.checkCancellation()
                let result: QobuzDownloadPlan
                switch request {
                case .track(let id):
                    result = try await resolveTrack(id: id, request: request)
                case .album(let id):
                    let album = try await service.album(id: id)
                    result = try plan(
                        album: album,
                        request: request,
                        collection: .album(id: album.id, title: album.displayTitle),
                        source: .album(album)
                    )
                case .playlist(let id):
                    result = try await resolvePlaylist(id: id, request: request)
                case .artist(let id):
                    result = try await resolveArtist(id: id, request: request)
                case .label(let id):
                    result = try await resolveLabel(id: id, request: request)
                }
                qobuzLog.notice(
                    "catalog.resolve",
                    "Catalog resolution completed",
                    metadata: [
                        "title": result.title,
                        "trackCount": String(result.tracks.count),
                        "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
                    ]
                )
                return result
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice("catalog.resolve", "Catalog resolution cancelled")
                throw NativeQobuzError.cancelled
            } catch {
                qobuzLog.error(
                    "catalog.resolve",
                    "Catalog resolution failed",
                    metadata: ["durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))],
                    error: error
                )
                throw error
            }
        }
    }

    private func resolveTrack(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let track = try await service.track(id: id)
        guard track.accountAvailabilityIssue == nil else {
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
        return QobuzDownloadPlan(
            request: request,
            title: track.displayTitle,
            tracks: [resolved],
            source: .track(track)
        )
    }

    private func resolvePlaylist(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let playlist = try await service.playlist(id: id)
        let playableTracks = playlist.availableTracks
        guard !playableTracks.isEmpty else {
            throw NativeQobuzError.emptyCollection(playlist.name)
        }

        var albumIDs: [QobuzID] = []
        var seenAlbumIDs = Set<QobuzID>()
        for track in playableTracks {
            guard let albumID = track.album?.id else {
                throw NativeQobuzError.missingAlbum(track.id)
            }
            if seenAlbumIDs.insert(albumID).inserted { albumIDs.append(albumID) }
        }
        let albums = try await fetchAlbums(ids: albumIDs, omittingUnavailable: false)
        let albumCache = Dictionary(uniqueKeysWithValues: zip(albumIDs, albums).compactMap { id, album in
            album.map { (id, $0) }
        })
        var resolved: [QobuzResolvedTrack] = []
        qobuzLog.debug(
            "catalog.playlist",
            "Resolving playlist album metadata",
            metadata: ["playableTracks": String(playableTracks.count)]
        )
        let collection = QobuzCollection.playlist(id: playlist.id, title: playlist.name)
        for (offset, track) in playableTracks.enumerated() {
            try Task.checkCancellation()
            guard let albumID = track.album?.id else {
                throw NativeQobuzError.missingAlbum(track.id)
            }
            guard let album = albumCache[albumID] else { throw NativeQobuzError.missingAlbum(track.id) }
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
        return QobuzDownloadPlan(
            request: request,
            title: playlist.name,
            tracks: resolved,
            source: .playlist(playlist)
        )
    }

    private func resolveArtist(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let artist = try await service.artist(id: id)
        var seenAlbums = Set<QobuzID>()
        let summaries = artist.officialAlbums.filter { seenAlbums.insert($0.id).inserted }
        let albums = try await fetchAlbums(
            ids: summaries.map(\.id),
            omittingUnavailable: true
        ).compactMap { $0 }

        let trackCount = albums.reduce(into: 0) { $0 += $1.availableTracks.count }
        guard trackCount > 0 else {
            throw NativeQobuzError.emptyCollection(artist.name)
        }

        let collection = QobuzCollection.artist(id: artist.id, name: artist.name)
        let resolved = flatten(albums: albums, collection: collection, total: trackCount)
        return QobuzDownloadPlan(
            request: request,
            title: artist.name,
            tracks: resolved,
            source: .artist(artist)
        )
    }

    private func resolveLabel(id: QobuzID, request: QobuzRequest) async throws -> QobuzDownloadPlan {
        let label = try await service.label(id: id)
        var seenAlbums = Set<QobuzID>()
        let summaries = label.availableAlbums.filter { seenAlbums.insert($0.id).inserted }
        let albums = try await fetchAlbums(
            ids: summaries.map(\.id),
            omittingUnavailable: true
        ).compactMap { $0 }
        let trackCount = albums.reduce(into: 0) { $0 += $1.availableTracks.count }
        guard trackCount > 0 else {
            throw NativeQobuzError.emptyCollection(label.name)
        }
        let collection = QobuzCollection.label(id: label.id, name: label.name)
        return QobuzDownloadPlan(
            request: request,
            title: label.name,
            tracks: flatten(albums: albums, collection: collection, total: trackCount),
            source: .label(label)
        )
    }

    private func fetchAlbums(
        ids: [QobuzID],
        omittingUnavailable: Bool
    ) async throws -> [QobuzAlbum?] {
        qobuzLog.debug(
            "catalog.collection",
            "Fetching collection albums",
            metadata: ["albumCount": String(ids.count), "maximumConcurrency": "6"]
        )
        return try await withThrowingTaskGroup(
            of: (Int, QobuzAlbum?).self,
            returning: [QobuzAlbum?].self
        ) { group in
            let concurrency = min(6, ids.count)
            var nextIndex = 0
            var ordered = Array<QobuzAlbum?>(repeating: nil, count: ids.count)

            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await fetchAlbum(
                        at: index,
                        id: ids[index],
                        omittingUnavailable: omittingUnavailable
                    )
                }
            }

            while let (index, album) = try await group.next() {
                ordered[index] = album
                if nextIndex < ids.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        try await fetchAlbum(
                            at: index,
                            id: ids[index],
                            omittingUnavailable: omittingUnavailable
                        )
                    }
                }
            }
            let availableCount = ordered.compactMap { $0 }.count
            qobuzLog.info(
                "catalog.collection",
                "Collection albums fetched",
                metadata: [
                    "requestedAlbums": String(ids.count),
                    "availableAlbums": String(availableCount),
                    "skippedAlbums": String(ids.count - availableCount)
                ]
            )
            return ordered
        }
    }

    private func flatten(
        albums: [QobuzAlbum],
        collection: QobuzCollection,
        total trackCount: Int
    ) -> [QobuzResolvedTrack] {
        var position = 0
        var resolved: [QobuzResolvedTrack] = []
        resolved.reserveCapacity(trackCount)
        for album in albums {
            for track in album.availableTracks {
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
        return resolved
    }

    private func fetchAlbum(
        at index: Int,
        id: QobuzID,
        omittingUnavailable: Bool
    ) async throws -> (Int, QobuzAlbum?) {
        try Task.checkCancellation()
        do {
            let album = try await service.album(id: id)
            let isAvailable = !omittingUnavailable
                || (album.accountAvailabilityIssue == nil && !album.availableTracks.isEmpty)
            if !isAvailable {
                qobuzLog.warning(
                    "catalog.collection",
                    "Album omitted because it is unavailable or empty",
                    metadata: ["albumID": id.rawValue, "index": String(index)]
                )
            }
            return (index, isAvailable ? album : nil)
        } catch NativeQobuzError.unavailable(_) where omittingUnavailable {
            qobuzLog.warning(
                "catalog.collection",
                "Album omitted because Qobuz reported it unavailable",
                metadata: ["albumID": id.rawValue, "index": String(index)]
            )
            return (index, nil)
        }
    }

    private func plan(
        album: QobuzAlbum,
        request: QobuzRequest,
        collection: QobuzCollection,
        source: QobuzDownloadSource
    ) throws -> QobuzDownloadPlan {
        guard album.accountAvailabilityIssue == nil else {
            throw NativeQobuzError.unavailable("This album is unavailable for the account region.")
        }
        let playableTracks = album.availableTracks
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
        return QobuzDownloadPlan(request: request, title: album.displayTitle, tracks: tracks, source: source)
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
