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
            let body = #"{"albums":{"items":[{"id":"album-1","title":"19","artist":{"id":1,"name":"Adele"},"streamable":true,"downloadable":true,"displayable":true},{"id":"blocked","title":"19 (blocked)","artist":{"id":1,"name":"Adele"},"streamable":false,"downloadable":false,"displayable":false},{"id":"unknown","title":"Unknown availability","artist":{"id":1,"name":"Adele"}}]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let results = try await client.search("Adele 19", category: .albums, limit: 30)

        XCTAssertEqual(results.albums.map(\.title), ["19"])
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
            let body = #"{"tracks":{"items":[{"id":1,"title":"Hello","streamable":true,"downloadable":false},{"id":2,"title":"Blocked","streamable":false,"downloadable":true},{"id":3,"title":"Unknown"}]}}"#
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
