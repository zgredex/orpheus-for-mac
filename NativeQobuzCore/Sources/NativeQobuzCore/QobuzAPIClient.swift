import Foundation

public final class QobuzAPIClient: QobuzCatalogService, QobuzBrowsingService, @unchecked Sendable {
    private let credentials: QobuzCredentials
    private let transport: QobuzHTTPTransport
    private let signer: QobuzRequestSigner

    public init(
        credentials: QobuzCredentials,
        session: URLSession = .shared,
        retryPolicy: QobuzRetryPolicy = .standard,
        baseURL: URL = URL(string: "https://www.qobuz.com/api.json/0.2/")!,
        timestamp: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.credentials = credentials
        transport = QobuzHTTPTransport(
            baseURL: baseURL,
            authToken: credentials.authToken,
            session: session,
            retryPolicy: retryPolicy,
            sleep: sleep,
            now: now,
            jitter: jitter
        )
        signer = QobuzRequestSigner(appSecret: credentials.appSecret, timestamp: timestamp)
    }

    public func validateAccount() async throws -> String? {
        try requireCredentials()
        let (account, response): (QobuzAccountResponse, HTTPURLResponse) = try await signedGet(
            endpoint: "user/get",
            parameters: ["app_id": credentials.appID]
        )
        guard account.credential?.parameters?.isEmpty == false else {
            throw NativeQobuzError.freeAccount
        }
        if let country = account.country?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
            return String(country.prefix(2)).uppercased()
        }
        if let store = response.value(forHTTPHeaderField: "X-Store"), store.count >= 2 {
            return String(store.prefix(2)).uppercased()
        }
        return nil
    }

    public func track(id: QobuzID) async throws -> QobuzTrack {
        let (value, _): (QobuzTrack, HTTPURLResponse) = try await get(
            endpoint: "track/get",
            parameters: ["track_id": id.rawValue, "app_id": credentials.appID]
        )
        return value
    }

    public func album(id: QobuzID) async throws -> QobuzAlbum {
        let (value, _): (QobuzAlbum, HTTPURLResponse) = try await get(
            endpoint: "album/get",
            parameters: [
                "album_id": id.rawValue,
                "app_id": credentials.appID,
                "extra": "albumsFromSameArtist,focusAll"
            ]
        )
        return value
    }

    public func playlist(id: QobuzID) async throws -> QobuzPlaylist {
        let pageSize = 500
        let first = try await playlistPage(id: id, offset: 0, limit: pageSize)
        let reportedTotal = first.tracksTotal ?? first.tracksCount
        let tracks = try await qobuzAllPages(
            firstItems: first.tracks,
            firstOffset: first.tracksOffset ?? 0,
            firstReportedLimit: first.tracksLimit,
            total: reportedTotal,
            pageSize: pageSize
        ) { offset, limit in
            let page = try await self.playlistPage(id: id, offset: offset, limit: limit)
            return QobuzPaginationPage(items: page.tracks, reportedLimit: page.tracksLimit)
        }
        return QobuzPlaylist(
            id: first.id,
            name: first.name,
            tracks: tracks,
            image: first.image,
            owner: first.owner,
            createdAt: first.createdAt,
            updatedAt: first.updatedAt,
            duration: first.duration,
            description: first.playlistDescription,
            tracksCount: first.tracksCount ?? reportedTotal ?? tracks.count,
            artworkURLs: first.artworkURLs,
            tracksTotal: reportedTotal ?? tracks.count,
            tracksOffset: 0,
            tracksLimit: tracks.count
        )
    }

    public func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        let pageSize = 500
        let first = try await artistPage(id: id, offset: 0, limit: pageSize)
        let albums = try await qobuzAllAlbumPages(first: first, pageSize: pageSize) { offset, limit in
            try await self.artistPage(id: id, offset: offset, limit: limit)
        }
        return QobuzArtistCatalog(
            id: first.id,
            name: first.name,
            image: first.image,
            albums: albums,
            albumsTotal: first.albumsTotal ?? albums.count,
            albumsOffset: 0,
            albumsLimit: albums.count
        )
    }

    public func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        let pageSize = 500
        let first = try await labelPage(id: id, offset: 0, limit: pageSize)
        let albums = try await qobuzAllAlbumPages(first: first, pageSize: pageSize) { offset, limit in
            try await self.labelPage(id: id, offset: offset, limit: limit)
        }
        return QobuzLabelCatalog(
            id: first.id,
            name: first.name,
            slug: first.slug,
            albums: albums,
            albumsTotal: first.albumsTotal ?? albums.count,
            albumsOffset: 0,
            albumsLimit: albums.count
        )
    }

    public func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo {
        try requireCredentials()
        let (value, _): (QobuzFileInfo, HTTPURLResponse) = try await signedGet(
            endpoint: "track/getFileUrl",
            parameters: [
                "track_id": trackID.rawValue,
                "format_id": String(format.formatID),
                "intent": "stream",
                "sample": "false",
                "app_id": credentials.appID,
                "user_auth_token": credentials.authToken
            ]
        )
        return value
    }

    public func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> QobuzSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return QobuzSearchResults() }
        let requestedLimit = min(max(limit, 1), 100)
        let requestedOffset = max(offset, 0)
        let (value, _): (QobuzSearchResponse, HTTPURLResponse) = try await get(
            endpoint: "catalog/search",
            parameters: [
                "query": trimmed,
                "type": category.rawValue,
                "limit": String(requestedLimit),
                "offset": String(requestedOffset),
                "app_id": credentials.appID
            ]
        )
        switch category {
        case .albums:
            let page = value.albums
            let cursor = try QobuzPageCursor.searchPage(
                page,
                requestedOffset: requestedOffset,
                requestedLimit: requestedLimit
            )
            return QobuzSearchResults(
                albums: (page?.items ?? []).filter { $0.accountAvailabilityIssue == nil },
                offset: cursor.offset,
                nextOffset: cursor.nextOffset,
                total: page?.total
            )
        case .artists:
            let page = value.artists
            let cursor = try QobuzPageCursor.searchPage(
                page,
                requestedOffset: requestedOffset,
                requestedLimit: requestedLimit
            )
            return QobuzSearchResults(
                artists: page?.items ?? [],
                offset: cursor.offset,
                nextOffset: cursor.nextOffset,
                total: page?.total
            )
        case .playlists:
            let page = value.playlists
            let cursor = try QobuzPageCursor.searchPage(
                page,
                requestedOffset: requestedOffset,
                requestedLimit: requestedLimit
            )
            return QobuzSearchResults(
                playlists: page?.items ?? [],
                offset: cursor.offset,
                nextOffset: cursor.nextOffset,
                total: page?.total
            )
        case .tracks:
            let page = value.tracks
            let cursor = try QobuzPageCursor.searchPage(
                page,
                requestedOffset: requestedOffset,
                requestedLimit: requestedLimit
            )
            return QobuzSearchResults(
                tracks: (page?.items ?? []).filter { $0.accountAvailabilityIssue == nil },
                offset: cursor.offset,
                nextOffset: cursor.nextOffset,
                total: page?.total
            )
        }
    }

    public func playlistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzPlaylist {
        try await validatedCatalogPage(
            request: .playlist,
            id: id,
            offset: offset,
            limit: limit,
            reportedOffset: \.tracksOffset
        )
    }

    public func artistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzArtistCatalog {
        try await validatedCatalogPage(
            request: .artist,
            id: id,
            offset: offset,
            limit: limit,
            reportedOffset: \.albumsOffset
        )
    }

    public func labelPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzLabelCatalog {
        try await validatedCatalogPage(
            request: .label,
            id: id,
            offset: offset,
            limit: limit,
            reportedOffset: \.albumsOffset
        )
    }

    private func validatedCatalogPage<Value: Decodable>(
        request: QobuzCatalogPageRequest,
        id: QobuzID,
        offset: Int,
        limit: Int,
        reportedOffset: KeyPath<Value, Int?>
    ) async throws -> Value {
        let requestedOffset = max(offset, 0)
        let page: Value = try await catalogPage(
            endpoint: request.endpoint,
            identifierKey: request.identifierKey,
            id: id,
            extra: request.extra,
            offset: requestedOffset,
            limit: limit
        )
        _ = try QobuzPageCursor.validatedOffset(
            reportedOffset: page[keyPath: reportedOffset],
            requestedOffset: requestedOffset
        )
        return page
    }

    private func catalogPage<Value: Decodable>(
        endpoint: String,
        identifierKey: String,
        id: QobuzID,
        extra: String,
        offset: Int,
        limit: Int
    ) async throws -> Value {
        let offset = max(offset, 0)
        let limit = min(max(limit, 1), 500)
        let (value, _): (Value, HTTPURLResponse) = try await get(
            endpoint: endpoint,
            parameters: [
                identifierKey: id.rawValue,
                "app_id": credentials.appID,
                "extra": extra,
                "limit": String(limit),
                "offset": String(offset)
            ]
        )
        return value
    }

    private func requireCredentials() throws {
        guard credentials.isComplete else {
            qobuzLog.error(
                "api.auth",
                "Qobuz request blocked because credentials are incomplete",
                metadata: ["credentialsConfigured": "false"]
            )
            throw NativeQobuzError.missingCredentials
        }
    }

    private func signedGet<T: Decodable>(
        endpoint: String,
        parameters: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        try await transport.get(
            endpoint: endpoint,
            parameters: signer.signedParameters(endpoint: endpoint, parameters: parameters)
        )
    }

    private func get<T: Decodable>(
        endpoint: String,
        parameters: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        try await transport.get(endpoint: endpoint, parameters: parameters)
    }
}
