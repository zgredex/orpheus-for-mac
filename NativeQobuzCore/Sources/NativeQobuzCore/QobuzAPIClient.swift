import CryptoKit
import Foundation

public protocol QobuzCatalogService: Sendable {
    func validateAccount() async throws -> String
    func track(id: QobuzID) async throws -> QobuzTrack
    func album(id: QobuzID) async throws -> QobuzAlbum
    func playlist(id: QobuzID) async throws -> QobuzPlaylist
    func artist(id: QobuzID) async throws -> QobuzArtistCatalog
    func label(id: QobuzID) async throws -> QobuzLabelCatalog
    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo
}

public extension QobuzCatalogService {
    func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        throw NativeQobuzError.unavailable("Label browsing is not supported by this catalog service.")
    }
}

public protocol QobuzBrowsingService: Sendable {
    func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int,
        offset: Int
    ) async throws -> QobuzSearchResults
}

public extension QobuzBrowsingService {
    func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int
    ) async throws -> QobuzSearchResults {
        try await search(query, category: category, limit: limit, offset: 0)
    }
}

public struct QobuzRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let baseDelay: Duration

    public init(maxAttempts: Int = 3, baseDelay: Duration = .milliseconds(350)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
    }

    public static let standard = QobuzRetryPolicy()
}

public final class QobuzAPIClient: QobuzCatalogService, QobuzBrowsingService, @unchecked Sendable {
    private let baseURL: URL
    private let credentials: QobuzCredentials
    private let session: URLSession
    private let retryPolicy: QobuzRetryPolicy
    private let timestamp: @Sendable () -> Int64
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        credentials: QobuzCredentials,
        session: URLSession = .shared,
        retryPolicy: QobuzRetryPolicy = .standard,
        baseURL: URL = URL(string: "https://www.qobuz.com/api.json/0.2/")!,
        timestamp: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.credentials = credentials
        self.session = session
        self.retryPolicy = retryPolicy
        self.baseURL = baseURL
        self.timestamp = timestamp
        self.sleep = sleep
    }

    public func validateAccount() async throws -> String {
        try requireCredentials()
        let (account, response): (AccountResponse, HTTPURLResponse) = try await signedGet(
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
        return "??"
    }

    public func track(id: QobuzID) async throws -> QobuzTrack {
        let (value, _): (QobuzTrack, HTTPURLResponse) = try await get(
            endpoint: "track/get",
            parameters: [
                "track_id": id.rawValue,
                "app_id": credentials.appID
            ]
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
        var tracks = first.tracks
        let total = first.tracksTotal ?? first.tracksCount ?? tracks.count
        var offset = (first.tracksOffset ?? 0) + tracks.count
        while offset < total {
            try Task.checkCancellation()
            let page = try await playlistPage(id: id, offset: offset, limit: pageSize)
            guard !page.tracks.isEmpty else { break }
            tracks.append(contentsOf: page.tracks)
            offset += page.tracks.count
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
            tracksCount: first.tracksCount ?? total,
            artworkURLs: first.artworkURLs,
            tracksTotal: total,
            tracksOffset: 0,
            tracksLimit: tracks.count
        )
    }

    private func playlistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzPlaylist {
        let (value, _): (QobuzPlaylist, HTTPURLResponse) = try await get(
            endpoint: "playlist/get",
            parameters: [
                "playlist_id": id.rawValue,
                "app_id": credentials.appID,
                "extra": "tracks,subscribers,focusAll",
                "limit": String(limit),
                "offset": String(offset)
            ]
        )
        return value
    }

    public func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        let pageSize = 500
        let first = try await artistPage(id: id, offset: 0, limit: pageSize)
        var albums = first.albums
        let total = first.albumsTotal ?? albums.count
        var offset = (first.albumsOffset ?? 0) + albums.count
        while offset < total {
            try Task.checkCancellation()
            let page = try await artistPage(id: id, offset: offset, limit: pageSize)
            guard !page.albums.isEmpty else { break }
            albums.append(contentsOf: page.albums)
            offset += page.albums.count
        }
        return QobuzArtistCatalog(
            id: first.id,
            name: first.name,
            image: first.image,
            albums: albums,
            albumsTotal: total,
            albumsOffset: 0,
            albumsLimit: albums.count
        )
    }

    private func artistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzArtistCatalog {
        let (value, _): (QobuzArtistCatalog, HTTPURLResponse) = try await get(
            endpoint: "artist/get",
            parameters: [
                "artist_id": id.rawValue,
                "app_id": credentials.appID,
                "extra": "albums,playlists,tracks_appears_on,albums_with_last_release,focusAll",
                "limit": String(limit),
                "offset": String(offset)
            ]
        )
        return value
    }

    public func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        let pageSize = 500
        let first = try await labelPage(id: id, offset: 0, limit: pageSize)
        var albums = first.albums
        let total = first.albumsTotal ?? albums.count
        var offset = (first.albumsOffset ?? 0) + albums.count
        while offset < total {
            try Task.checkCancellation()
            let page = try await labelPage(id: id, offset: offset, limit: pageSize)
            guard !page.albums.isEmpty else { break }
            albums.append(contentsOf: page.albums)
            offset += page.albums.count
        }
        return QobuzLabelCatalog(
            id: first.id,
            name: first.name,
            slug: first.slug,
            albums: albums,
            albumsTotal: total,
            albumsOffset: 0,
            albumsLimit: albums.count
        )
    }

    private func labelPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzLabelCatalog {
        let (value, _): (QobuzLabelCatalog, HTTPURLResponse) = try await get(
            endpoint: "label/get",
            parameters: [
                "label_id": id.rawValue,
                "app_id": credentials.appID,
                "extra": "albums",
                "limit": String(limit),
                "offset": String(offset)
            ]
        )
        return value
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
        let (value, _): (SearchResponse, HTTPURLResponse) = try await get(
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
            let raw = page?.items ?? []
            let albums = raw
                .filter { $0.accountAvailabilityIssue == nil }
            return QobuzSearchResults(
                albums: albums,
                offset: page?.offset ?? requestedOffset,
                nextOffset: nextOffset(for: page, fallbackOffset: requestedOffset, requestedLimit: requestedLimit),
                total: page?.total
            )
        case .artists:
            let page = value.artists
            return QobuzSearchResults(
                artists: page?.items ?? [],
                offset: page?.offset ?? requestedOffset,
                nextOffset: nextOffset(for: page, fallbackOffset: requestedOffset, requestedLimit: requestedLimit),
                total: page?.total
            )
        case .playlists:
            let page = value.playlists
            return QobuzSearchResults(
                playlists: page?.items ?? [],
                offset: page?.offset ?? requestedOffset,
                nextOffset: nextOffset(for: page, fallbackOffset: requestedOffset, requestedLimit: requestedLimit),
                total: page?.total
            )
        case .tracks:
            let page = value.tracks
            let raw = page?.items ?? []
            let tracks = raw
                .filter { $0.accountAvailabilityIssue == nil }
            return QobuzSearchResults(
                tracks: tracks,
                offset: page?.offset ?? requestedOffset,
                nextOffset: nextOffset(for: page, fallbackOffset: requestedOffset, requestedLimit: requestedLimit),
                total: page?.total
            )
        }
    }

    private func nextOffset<Value>(
        for page: SearchResponse.Items<Value>?,
        fallbackOffset: Int,
        requestedLimit: Int
    ) -> Int? {
        guard let page, !page.items.isEmpty else { return nil }
        let candidate = (page.offset ?? fallbackOffset) + page.items.count
        if let total = page.total {
            return candidate < total ? candidate : nil
        }
        return page.items.count >= requestedLimit ? candidate : nil
    }

    static func signature(
        endpoint: String,
        parameters: [String: String],
        timestamp: Int64,
        appSecret: String
    ) -> String {
        var input = endpoint.replacingOccurrences(of: "/", with: "")
        for key in parameters.keys.sorted() where key != "app_id" && key != "user_auth_token" {
            input += key + (parameters[key] ?? "")
        }
        input += String(timestamp) + appSecret
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        qobuzLog.trace(
            "api.signing",
            "Preparing signed Qobuz request",
            metadata: ["endpoint": endpoint, "parameterCount": String(parameters.count)]
        )
        let requestTimestamp = timestamp()
        var signed = parameters
        signed["request_ts"] = String(requestTimestamp)
        signed["request_sig"] = Self.signature(
            endpoint: endpoint,
            parameters: parameters,
            timestamp: requestTimestamp,
            appSecret: credentials.appSecret
        )
        return try await get(endpoint: endpoint, parameters: signed)
    }

    private func get<T: Decodable>(
        endpoint: String,
        parameters: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        let requestID = UUID().uuidString
        let requestStarted = Date()
        let baseMetadata = [
            "requestID": requestID,
            "endpoint": endpoint,
            "responseType": String(reflecting: T.self),
            "parameterNames": parameters.keys.sorted().joined(separator: ",")
        ]
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        ) else {
            qobuzLog.error("api.request", "Could not construct Qobuz endpoint", metadata: baseMetadata)
            throw NativeQobuzError.invalidResponse("Could not construct endpoint \(endpoint).")
        }
        components.queryItems = parameters
            .filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name
            }
        guard let url = components.url else {
            qobuzLog.error("api.request", "Could not construct Qobuz request URL", metadata: baseMetadata)
            throw NativeQobuzError.invalidResponse("Could not construct a Qobuz request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers

        qobuzLog.info(
            "api.request",
            "Qobuz request started",
            metadata: baseMetadata.merging([
                "method": "GET",
                "host": url.host ?? "unknown",
                "maxAttempts": String(retryPolicy.maxAttempts)
            ]) { _, new in new }
        )

        for attempt in 0..<retryPolicy.maxAttempts {
            let attemptStarted = Date()
            let attemptMetadata = baseMetadata.merging([
                "attempt": String(attempt + 1),
                "maxAttempts": String(retryPolicy.maxAttempts)
            ]) { _, new in new }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    qobuzLog.error(
                        "api.response",
                        "Qobuz returned a non-HTTP response",
                        metadata: attemptMetadata
                    )
                    throw NativeQobuzError.invalidResponse("Expected an HTTP response.")
                }
                let responseMetadata = attemptMetadata.merging([
                    "status": String(http.statusCode),
                    "responseBytes": String(data.count),
                    "durationMs": String(Int(Date().timeIntervalSince(attemptStarted) * 1_000))
                ]) { _, new in new }
                qobuzLog.debug("api.response", "Qobuz response received", metadata: responseMetadata)
                if (200...202).contains(http.statusCode) {
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        qobuzLog.info(
                            "api.request",
                            "Qobuz request completed",
                            metadata: responseMetadata.merging([
                                "totalDurationMs": String(Int(Date().timeIntervalSince(requestStarted) * 1_000))
                            ]) { _, new in new }
                        )
                        return (decoded, http)
                    } catch {
                        qobuzLog.error(
                            "api.decode",
                            "Could not decode Qobuz response",
                            metadata: responseMetadata,
                            error: error
                        )
                        throw NativeQobuzError.invalidResponse(String(describing: error))
                    }
                }
                if isRetryable(status: http.statusCode), attempt + 1 < retryPolicy.maxAttempts {
                    qobuzLog.warning(
                        "api.retry",
                        "Qobuz request will retry after HTTP failure",
                        metadata: responseMetadata
                    )
                    try await wait(attempt: attempt, response: http)
                    continue
                }
                let mapped = mapHTTPError(status: http.statusCode, data: data, response: http)
                qobuzLog.error(
                    "api.request",
                    "Qobuz request failed with HTTP error",
                    metadata: responseMetadata,
                    error: mapped
                )
                throw mapped
            } catch is CancellationError {
                qobuzLog.notice("api.request", "Qobuz request cancelled", metadata: attemptMetadata)
                throw NativeQobuzError.cancelled
            } catch let error as NativeQobuzError {
                if case .cancelled = error {
                    qobuzLog.notice("api.request", "Qobuz request cancelled", metadata: attemptMetadata)
                } else {
                    qobuzLog.error(
                        "api.request",
                        "Qobuz request stopped",
                        metadata: attemptMetadata,
                        error: error
                    )
                }
                throw error
            } catch {
                let networkFailure = NativeQobuzError.networkFailure(error)
                if networkFailure.isConnectivityLoss {
                    qobuzLog.warning(
                        "api.connectivity",
                        "Qobuz request stopped because the network path is unavailable",
                        metadata: attemptMetadata,
                        error: networkFailure
                    )
                    throw networkFailure
                }
                if isRetryable(error: error), attempt + 1 < retryPolicy.maxAttempts {
                    qobuzLog.warning(
                        "api.retry",
                        "Qobuz request will retry after network failure",
                        metadata: attemptMetadata,
                        error: error
                    )
                    try await wait(attempt: attempt, response: nil)
                    continue
                }
                qobuzLog.error(
                    "api.request",
                    "Qobuz request failed with a network error",
                    metadata: attemptMetadata,
                    error: error
                )
                throw networkFailure
            }
        }
        qobuzLog.error(
            "api.request",
            "Qobuz request exhausted all retry attempts",
            metadata: baseMetadata.merging([
                "totalDurationMs": String(Int(Date().timeIntervalSince(requestStarted) * 1_000))
            ]) { _, new in new }
        )
        throw NativeQobuzError.network("Request failed after retrying.")
    }

    private var headers: [String: String] {
        var values = [
            "X-Device-Platform": "android",
            "X-Device-Model": "Pixel 3",
            "X-Device-Os-Version": "10",
            "X-Device-Manufacturer-Id": "482D8CB7-015D-402F-A93B-5EEF0E0996F3",
            "X-App-Version": "5.16.1.5",
            "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 10; Pixel 3 Build/QP1A.190711.020))QobuzMobileAndroid/5.16.1.5-b21041415"
        ]
        if !credentials.authToken.isEmpty {
            values["X-User-Auth-Token"] = credentials.authToken
        }
        return values
    }

    private func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    private func isRetryable(error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed
        ].contains(code)
    }

    private func wait(attempt: Int, response: HTTPURLResponse?) async throws {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
            try await sleep(.seconds(min(max(retryAfter, 0), 5)))
            return
        }
        let multiplier = 1 << min(attempt, 4)
        try await sleep(retryPolicy.baseDelay * multiplier)
    }

    private func mapHTTPError(status: Int, data: Data, response: HTTPURLResponse) -> NativeQobuzError {
        let body = String(data: data, encoding: .utf8) ?? ""
        if status == 401 || status == 403 {
            return .invalidCredentials
        }
        if status == 404 {
            let region = response.value(forHTTPHeaderField: "X-Store").map { String($0.prefix(2)).uppercased() }
            let suffix = region.map { " It may belong to the \($0) store." } ?? ""
            return .unavailable("This Qobuz item is unavailable for the account region.\(suffix)")
        }
        return .http(status, body.isEmpty ? "No response body" : body)
    }
}

private struct SearchResponse: Decodable {
    let albums: Items<QobuzAlbumSummary>?
    let artists: Items<QobuzArtist>?
    let playlists: Items<QobuzPlaylist>?
    let tracks: Items<QobuzTrack>?

    struct Items<Value: Decodable>: Decodable {
        let items: [Value]
        let offset: Int?
        let limit: Int?
        let total: Int?
    }
}

private struct AccountResponse: Decodable {
    let country: String?
    let credential: Credential?

    struct Credential: Decodable {
        let parameters: [String: JSONFragment]?
    }
}

private enum JSONFragment: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONFragment])
    case array([JSONFragment])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONFragment].self) { self = .object(value) }
        else if let value = try? container.decode([JSONFragment].self) { self = .array(value) }
        else {
            throw DecodingError.typeMismatch(
                JSONFragment.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
}
