import Foundation
import XCTest
@testable import NativeQobuzCore

final class APITests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testSignatureMatchesPythonReferenceAlgorithm() {
        let signature = QobuzAPIClient.signature(
            endpoint: "track/getFileUrl",
            parameters: [
                "track_id": "123",
                "format_id": "27",
                "intent": "stream",
                "sample": "false",
                "app_id": "app",
                "user_auth_token": "token"
            ],
            timestamp: 1_700_000_000,
            appSecret: "secret"
        )

        XCTAssertEqual(signature, "fa5d1d165d303c6a5e5b06b2f34bd56e")
    }

    func testFileInfoUsesSignedQobuzRequestAndDeviceHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBox = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            requestBox.set(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"url":"https://media.example/track.flac","format_id":27,"bit_depth":24,"sampling_rate":96}"#
            return (response, Data(body.utf8))
        }

        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero),
            timestamp: { 1_700_000_000 }
        )
        let info = try await client.fileInfo(trackID: QobuzID("123"), quality: .hiRes)

        XCTAssertEqual(info.formatID, 27)
        XCTAssertEqual(info.bitDepth, 24)
        XCTAssertEqual(info.samplingRate, 96)
        let request = try XCTUnwrap(requestBox.value)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Platform"), "android")
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["request_ts"], "1700000000")
        XCTAssertEqual(query["request_sig"], "fa5d1d165d303c6a5e5b06b2f34bd56e")
        XCTAssertEqual(query["format_id"], "27")
        XCTAssertEqual(query["app_id"], "app")
        XCTAssertEqual(query["user_auth_token"], "token")
        XCTAssertNil(query["user_id"])
    }

    func testAccountValidationUsesApplicationIDAndNeverSendsUserID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBox = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            requestBox.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"id":"account-user","country":"FR","credential":{"parameters":{"lossless":true}}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "application-id", appSecret: "secret", authToken: "account-token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero),
            timestamp: { 1_700_000_000 }
        )

        let region = try await client.validateAccount()
        XCTAssertEqual(region, "FR")
        let request = try XCTUnwrap(requestBox.value)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["app_id"], "application-id")
        XCTAssertNil(query["user_id"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "account-token")
    }

    func testAccountRegionPrefersJSONCountry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Store": "US-en"]
            )!
            let body = #"{"country":"FR","credential":{"parameters":{"lossless":true}}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero),
            timestamp: { 1_700_000_000 }
        )

        let region = try await client.validateAccount()
        XCTAssertEqual(region, "FR")
    }

    func testSearchReturnsTypedCategoryAndUsesAccountHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBox = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            requestBox.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"albums":{"items":[{"id":"album-1","title":"19","artist":{"id":1,"name":"Adele"},"streamable":true,"downloadable":true,"displayable":true,"purchasable":true,"maximum_bit_depth":24,"maximum_sampling_rate":96,"hires_streamable":true},{"id":"blocked","title":"19 (blocked)","artist":{"id":1,"name":"Adele"},"streamable":false,"downloadable":false,"displayable":false},{"id":"store-blocked","title":"19 (not purchasable)","artist":{"id":1,"name":"Adele"},"streamable":true,"downloadable":true,"displayable":true,"purchasable":false},{"id":"unknown","title":"Unknown availability","artist":{"id":1,"name":"Adele"}}]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let results = try await client.search("Adele 19", category: .albums, limit: 30)

        XCTAssertEqual(results.albums.map(\.title), ["19"])
        XCTAssertEqual(results.albums.first?.maximumBitDepth, 24)
        XCTAssertEqual(results.albums.first?.maximumSamplingRate, 96)
        XCTAssertEqual(results.albums.first?.hiresStreamable, true)
        XCTAssertTrue(results.artists.isEmpty)
        let request = try XCTUnwrap(requestBox.value)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["query"], "Adele 19")
        XCTAssertEqual(query["type"], "albums")
        XCTAssertEqual(query["limit"], "60")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "token")
    }

    func testSearchFiltersUnstreamableTracksEvenWhenTheyAreDownloadable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"tracks":{"items":[{"id":1,"title":"Hello","streamable":true,"downloadable":false,"purchasable":true},{"id":2,"title":"Blocked","streamable":false,"downloadable":true},{"id":3,"title":"Unknown"},{"id":4,"title":"Store blocked","streamable":true,"downloadable":true,"purchasable":false}]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let results = try await client.search("Adele", category: .tracks, limit: 30)

        XCTAssertEqual(results.tracks.map(\.title), ["Hello"])
        XCTAssertTrue(results.tracks.allSatisfy(\.streamable))
    }

    func testSearchReturnsPlaylistResultsSupportedByPythonPlugin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBox = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            requestBox.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"playlists":{"items":[{"id":52736446,"name":"Qobuz Essentials","tracks_count":35,"owner":{"id":922179,"name":"Qobuz"},"image_rectangle":["https://static.qobuz.com/playlist.jpg"]}]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let results = try await client.search("essentials", category: .playlists, limit: 30)

        XCTAssertEqual(results.playlists.map(\.name), ["Qobuz Essentials"])
        XCTAssertEqual(results.playlists.first?.tracksCount, 35)
        XCTAssertEqual(results.playlists.first?.owner?.name, "Qobuz")
        let request = try XCTUnwrap(requestBox.value)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["type"], "playlists")
        XCTAssertEqual(query["app_id"], "app")
        XCTAssertNil(query["user_id"])
    }

    func testArtistFetchesEveryAlbumPageAndPreservesOrder() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let offsets = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            let query = Dictionary(
                uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") }
            )
            let offset = query["offset"] ?? ""
            offsets.set(offsets.value + [offset])
            let items: String
            switch offset {
            case "0":
                items = #"[{"id":"one","title":"One","artist":{"id":"artist","name":"Artist"}},{"id":"two","title":"Two","artist":{"id":"artist","name":"Artist"}}]"#
            case "2":
                items = #"[{"id":"three","title":"Three","artist":{"id":"artist","name":"Artist"}}]"#
            default:
                items = "[]"
            }
            let body = #"{"id":"artist","name":"Artist","albums":{"items":\#(items),"total":3,"offset":\#(offset),"limit":500}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let artist = try await client.artist(id: QobuzID("artist"))

        XCTAssertEqual(artist.albums.map(\.id.rawValue), ["one", "two", "three"])
        XCTAssertEqual(artist.albumsTotal, 3)
        XCTAssertEqual(offsets.value, ["0", "2"])
    }

    func testAlbumDecodesEveryMainArtistAndStructuredLabel() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"id":"f91ymo1s6vtgb","title":"Kids See Ghosts","artist":{"id":243465,"name":"Kids See Ghosts"},"artists":[{"id":243465,"name":"Kids See Ghosts","roles":["main-artist"]},{"id":3764,"name":"Kanye West","roles":["main-artist"]},{"id":5409,"name":"Kid Cudi","roles":["main-artist"]}],"label":{"id":123,"name":"Getting Out Our Dreams","slug":"good"},"description":"Album notes","tracks":{"items":[]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let album = try await client.album(id: QobuzID("f91ymo1s6vtgb"))

        XCTAssertEqual(album.mainArtists.map(\.name), ["Kids See Ghosts", "Kanye West", "Kid Cudi"])
        XCTAssertEqual(album.label, "Getting Out Our Dreams")
        XCTAssertEqual(album.labelInfo?.id, QobuzID("123"))
        XCTAssertEqual(album.albumDescription, "Album notes")
    }

    func testLabelFetchesEveryAlbumPageAndPreservesAccountAvailability() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let offsets = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let offset = query["offset"] ?? "0"
            offsets.set(offsets.value + [offset])
            let items = offset == "0"
                ? #"[{"id":"one","title":"One","artist":{"id":1,"name":"Artist"},"streamable":true,"displayable":true,"purchasable":true},{"id":"two","title":"Two","artist":{"id":1,"name":"Artist"},"streamable":true,"displayable":true,"purchasable":true}]"#
                : #"[{"id":"three","title":"Three","artist":{"id":1,"name":"Artist"},"streamable":false,"displayable":false,"purchasable":false}]"#
            let body = #"{"id":4587,"name":"Sony Music Entertainment","slug":"sony","albums":{"items":\#(items),"total":3,"offset":\#(offset),"limit":500}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let label = try await client.label(id: QobuzID("4587"))

        XCTAssertEqual(label.albums.map(\.id.rawValue), ["one", "two", "three"])
        XCTAssertEqual(label.availableAlbums.map(\.id.rawValue), ["one", "two"])
        XCTAssertEqual(offsets.value, ["0", "2"])
    }

    func testPlaylistDecodesOwnerDatesDescriptionDurationAndArtwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"id":52736446,"name":"Qobuz: The Power of Seven","description":"Playlist notes","duration":9201,"created_at":1768330514,"updated_at":1783719712,"tracks_count":35,"owner":{"id":922179,"name":"Qobuz"},"image_rectangle":["https://static.qobuz.com/images/playlists/cover.jpg"],"tracks":{"items":[]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let playlist = try await client.playlist(id: QobuzID("52736446"))

        XCTAssertEqual(playlist.owner?.name, "Qobuz")
        XCTAssertEqual(playlist.createdAt, 1_768_330_514)
        XCTAssertEqual(playlist.updatedAt, 1_783_719_712)
        XCTAssertEqual(playlist.duration, 9_201)
        XCTAssertEqual(playlist.tracksCount, 35)
        XCTAssertEqual(playlist.playlistDescription, "Playlist notes")
        XCTAssertEqual(playlist.artworkURL?.lastPathComponent, "cover.jpg")
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }
    func set(_ value: Value) { lock.withLock { storage = value } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
