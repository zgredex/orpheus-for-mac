import CryptoKit
import Foundation

protocol QobuzServicing: AnyObject {
    func validateAccount() async throws -> String
    func region() async throws -> String
    func getAlbum(id: String) async throws -> QobuzAlbumResponse
    func getTrack(id: String) async throws -> QobuzTrackResponse
    func getArtist(id: String) async throws -> QobuzArtistResponse
    func getPlaylist(id: String) async throws -> QobuzPlaylistResponse
    func getFileURL(trackID: String, quality: String) async throws -> QobuzFileURLResponse
    func search(query: String, type: SearchType, limit: Int) async throws -> QobuzSearchResponse
}

final class QobuzAPI: QobuzServicing {
    private let baseURL = URL(string: "https://www.qobuz.com/api.json/0.2/")!
    private let appID: String
    private let appSecret: String
    private let authToken: String
    private let session: URLSession

    init(appID: String, appSecret: String, authToken: String, session: URLSession = .shared) {
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func checkToken() async throws -> Bool {
        _ = try await validateAccount()
        return true
    }

    func validateAccount() async throws -> String {
        let (response, http): (QobuzUserResponse, HTTPURLResponse) = try await signedGetWithResponse(
            "user/get",
            params: ["app_id": appID]
        )
        try validateCredential(response)
        return region(from: response, response: http)
    }

    func region() async throws -> String {
        let (response, http): (QobuzUserResponse, HTTPURLResponse) = try await signedGetWithResponse(
            "user/get",
            params: ["app_id": appID]
        )
        return region(from: response, response: http)
    }

    private func validateCredential(_ response: QobuzUserResponse) throws {
        guard let parameters = response.credential?.parameters,
              parameters.hasPythonTruthyValue else {
            throw QobuzError.freeAccount
        }
    }

    private func region(from response: QobuzUserResponse, response http: HTTPURLResponse) -> String {
        if let country = response.country?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
            return String(country.prefix(2)).uppercased()
        }
        return Self.countryCode(fromStoreHeader: http.value(forHTTPHeaderField: "X-Store")) ?? "??"
    }

    func getAlbum(id: String) async throws -> QobuzAlbumResponse {
        try await get("album/get", params: [
            "album_id": id,
            "app_id": appID,
            "extra": "albumsFromSameArtist,focusAll"
        ])
    }

    func getTrack(id: String) async throws -> QobuzTrackResponse {
        try await get("track/get", params: [
            "track_id": id,
            "app_id": appID
        ])
    }

    func getArtist(id: String) async throws -> QobuzArtistResponse {
        try await get("artist/get", params: [
            "artist_id": id,
            "app_id": appID,
            "extra": "albums,playlists,tracks_appears_on,albums_with_last_release,focusAll",
            "limit": "1000",
            "offset": "0"
        ])
    }

    func getPlaylist(id: String) async throws -> QobuzPlaylistResponse {
        try await get("playlist/get", params: [
            "playlist_id": id,
            "app_id": appID,
            "extra": "tracks,subscribers,focusAll",
            "limit": "2000",
            "offset": "0"
        ])
    }

    func getFileURL(trackID: String, quality: String) async throws -> QobuzFileURLResponse {
        guard let formatID = QobuzDownloadQuality.formatID(for: quality) else {
            throw QobuzError.apiError("Unsupported Qobuz quality: \(quality)")
        }

        return try await signedGet("track/getFileUrl", params: [
            "track_id": trackID,
            "format_id": String(formatID),
            "intent": "stream",
            "sample": "false",
            "app_id": appID,
            "user_auth_token": authToken
        ])
    }

    func search(query: String, type: SearchType, limit: Int = 10) async throws -> QobuzSearchResponse {
        try await get("catalog/search", params: [
            "query": query,
            "type": type.rawValue,
            "limit": String(limit),
            "app_id": appID
        ])
    }

    private func signedGet<T: Decodable>(_ endpoint: String, params: [String: String]) async throws -> T {
        let (result, _): (T, HTTPURLResponse) = try await signedGetWithResponse(endpoint, params: params)
        return result
    }

    private func signedGetWithResponse<T: Decodable>(
        _ endpoint: String,
        params: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        let signature = createSignature(method: endpoint, parameters: params)
        var signedParams = params
        signedParams["request_ts"] = signature.timestamp
        signedParams["request_sig"] = signature.signature
        return try await getWithResponse(endpoint, params: signedParams)
    }

    private func get<T: Decodable>(_ endpoint: String, params: [String: String]) async throws -> T {
        let (result, _): (T, HTTPURLResponse) = try await getWithResponse(endpoint, params: params)
        return result
    }

    private func getWithResponse<T: Decodable>(
        _ endpoint: String,
        params: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = params
            .filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }

        guard let url = components.url else {
            throw QobuzError.apiError("Invalid Qobuz API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers()

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QobuzError.apiError("Invalid Qobuz API response")
        }

        guard (200...202).contains(http.statusCode) else {
            throw mapHTTPError(statusCode: http.statusCode, data: data, response: http)
        }

        do {
            return (try JSONDecoder().decode(T.self, from: data), http)
        } catch {
            throw QobuzError.apiError("Could not decode Qobuz response: \(error.localizedDescription)")
        }
    }

    private func headers() -> [String: String] {
        var headers = [
            "X-Device-Platform": "android",
            "X-Device-Model": "Pixel 3",
            "X-Device-Os-Version": "10",
            "X-Device-Manufacturer-Id": "482D8CB7-015D-402F-A93B-5EEF0E0996F3",
            "X-App-Version": "5.16.1.5",
            "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 10; Pixel 3 Build/QP1A.190711.020))QobuzMobileAndroid/5.16.1.5-b21041415"
        ]
        if !authToken.isEmpty {
            headers["X-User-Auth-Token"] = authToken
        }
        return headers
    }

    private func createSignature(method: String, parameters: [String: String]) -> (timestamp: String, signature: String) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var toHash = method.replacingOccurrences(of: "/", with: "")
        for key in parameters.keys.sorted() where key != "app_id" && key != "user_auth_token" {
            toHash += key + (parameters[key] ?? "")
        }
        toHash += timestamp + appSecret

        let digest = Insecure.MD5.hash(data: Data(toHash.utf8))
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        return (timestamp, signature)
    }

    private func mapHTTPError(statusCode: Int, data: Data, response: HTTPURLResponse) -> QobuzError {
        let body = String(data: data, encoding: .utf8) ?? ""
        if statusCode == 401 || statusCode == 403 {
            return .invalidToken
        }
        if statusCode == 404, body.localizedCaseInsensitiveContains("No result matching") {
            return .regionBlocked(storeHeader: response.value(forHTTPHeaderField: "X-Store"))
        }
        let lowercasedBody = body.lowercased()
        if lowercasedBody.contains("invalid user")
            || lowercasedBody.contains("invalid token")
            || lowercasedBody.contains("expired token")
            || lowercasedBody.contains("unauthorized") {
            return .invalidToken
        }
        return .apiError(body.isEmpty ? "HTTP \(statusCode)" : body)
    }

    private static func countryCode(fromStoreHeader store: String?) -> String? {
        guard let store, store.count >= 2 else { return nil }
        return String(store.prefix(2)).uppercased()
    }
}

enum QobuzDownloadQuality {
    static func formatID(for quality: String) -> Int? {
        switch quality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hifi":
            return 27
        case "lossless":
            return 6
        case "high":
            return 5
        default:
            return nil
        }
    }
}

enum QobuzError: LocalizedError, Equatable {
    case apiError(String)
    case invalidToken
    case freeAccount
    case missingCredentials
    case regionBlocked(storeHeader: String?)

    var errorDescription: String? {
        switch self {
        case .apiError(let message):
            return "Qobuz API error: \(message)"
        case .invalidToken:
            return "Invalid or expired Qobuz credentials. Check Settings."
        case .freeAccount:
            return "This Qobuz account is not eligible for downloading."
        case .missingCredentials:
            return "Missing Qobuz credentials. Open Settings to add your app ID, app secret, and auth token."
        case .regionBlocked(let storeHeader):
            let country = storeHeader.map { String($0.prefix(2)).uppercased() } ?? "another region"
            return "This Qobuz item is not available for the current account region. It appears to be available in \(country)."
        }
    }

    var blockedCountry: String? {
        if case .regionBlocked(let storeHeader) = self, let storeHeader {
            return String(storeHeader.prefix(2)).uppercased()
        }
        return nil
    }
}

private extension JSONValue {
    var hasPythonTruthyValue: Bool {
        switch self {
        case .object(let value):
            return !value.isEmpty
        case .array(let value):
            return !value.isEmpty
        case .string(let value):
            return !value.isEmpty
        case .number(let value):
            return value != 0
        case .bool(let value):
            return value
        case .null:
            return false
        }
    }
}
