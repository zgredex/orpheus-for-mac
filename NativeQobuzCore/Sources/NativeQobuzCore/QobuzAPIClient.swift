import CryptoKit
import Foundation

public protocol QobuzCatalogService: Sendable {
    func validateAccount() async throws -> String
    func track(id: QobuzID) async throws -> QobuzTrack
    func album(id: QobuzID) async throws -> QobuzAlbum
    func playlist(id: QobuzID) async throws -> QobuzPlaylist
    func artist(id: QobuzID) async throws -> QobuzArtistCatalog
    func fileInfo(trackID: QobuzID, quality: QobuzQuality) async throws -> QobuzFileInfo
}

public protocol QobuzBrowsingService: Sendable {
    func search(_ query: String, category: QobuzSearchCategory, limit: Int) async throws -> QobuzSearchResults
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
        let (value, _): (QobuzPlaylist, HTTPURLResponse) = try await get(
            endpoint: "playlist/get",
            parameters: [
                "playlist_id": id.rawValue,
                "app_id": credentials.appID,
                "extra": "tracks,subscribers,focusAll",
                "limit": "2000",
                "offset": "0"
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

    public func fileInfo(trackID: QobuzID, quality: QobuzQuality) async throws -> QobuzFileInfo {
        try requireCredentials()
        let (value, _): (QobuzFileInfo, HTTPURLResponse) = try await signedGet(
            endpoint: "track/getFileUrl",
            parameters: [
                "track_id": trackID.rawValue,
                "format_id": String(quality.formatID),
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
        limit: Int = 30
    ) async throws -> QobuzSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return QobuzSearchResults() }
        let requestedLimit = min(max(limit, 1), 100)
        let apiLimit = category == .artists ? requestedLimit : min(requestedLimit * 2, 100)
        let (value, _): (SearchResponse, HTTPURLResponse) = try await get(
            endpoint: "catalog/search",
            parameters: [
                "query": trimmed,
                "type": category.rawValue,
                "limit": String(apiLimit),
                "offset": "0",
                "app_id": credentials.appID
            ]
        )
        switch category {
        case .albums:
            let albums = (value.albums?.items ?? []).filter(\.streamable).prefix(requestedLimit)
            return QobuzSearchResults(albums: Array(albums))
        case .artists: return QobuzSearchResults(artists: value.artists?.items ?? [])
        case .tracks:
            let tracks = (value.tracks?.items ?? []).filter(\.streamable).prefix(requestedLimit)
            return QobuzSearchResults(tracks: Array(tracks))
        }
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
        guard credentials.isComplete else { throw NativeQobuzError.missingCredentials }
    }

    private func signedGet<T: Decodable>(
        endpoint: String,
        parameters: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
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
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        ) else {
            throw NativeQobuzError.invalidResponse("Could not construct endpoint \(endpoint).")
        }
        components.queryItems = parameters
            .filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name
            }
        guard let url = components.url else {
            throw NativeQobuzError.invalidResponse("Could not construct a Qobuz request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers

        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NativeQobuzError.invalidResponse("Expected an HTTP response.")
                }
                if (200...202).contains(http.statusCode) {
                    do {
                        return (try JSONDecoder().decode(T.self, from: data), http)
                    } catch {
                        throw NativeQobuzError.invalidResponse(String(describing: error))
                    }
                }
                if isRetryable(status: http.statusCode), attempt + 1 < retryPolicy.maxAttempts {
                    try await wait(attempt: attempt, response: http)
                    continue
                }
                throw mapHTTPError(status: http.statusCode, data: data, response: http)
            } catch is CancellationError {
                throw NativeQobuzError.cancelled
            } catch let error as NativeQobuzError {
                throw error
            } catch {
                if isRetryable(error: error), attempt + 1 < retryPolicy.maxAttempts {
                    try await wait(attempt: attempt, response: nil)
                    continue
                }
                throw NativeQobuzError.network(error.localizedDescription)
            }
        }
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
    let tracks: Items<QobuzTrack>?

    struct Items<Value: Decodable>: Decodable {
        let items: [Value]
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
