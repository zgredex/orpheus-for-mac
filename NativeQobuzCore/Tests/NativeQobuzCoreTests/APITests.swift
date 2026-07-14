import Foundation
import XCTest
@testable import NativeQobuzCore

final class APITests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testQualityIsMaximumPolicyWhileAudioFormatIsExact() {
        XCTAssertEqual(QobuzQuality.mp3.maximumFormat, .mp3)
        XCTAssertEqual(QobuzQuality.lossless.maximumFormat, .lossless)
        XCTAssertEqual(QobuzQuality.hiRes.maximumFormat, .hiRes)
        XCTAssertEqual(QobuzAudioFormat(formatID: 7), .hiRes96)
        XCTAssertEqual(QobuzAudioFormat.hiRes96.formatID, 7)
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
            let body = #"{"url":"https://media.example/track.flac","format_id":6,"bit_depth":16,"sampling_rate":44.1,"restrictions":[{"code":"FormatRestrictedByFormatAvailability"}]}"#
            return (response, Data(body.utf8))
        }

        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero),
            timestamp: { 1_700_000_000 }
        )
        let info = try await client.fileInfo(trackID: QobuzID("123"), format: .hiRes)

        XCTAssertEqual(info.formatID, 6)
        XCTAssertEqual(info.bitDepth, 16)
        XCTAssertEqual(info.samplingRate, 44.1)
        XCTAssertEqual(info.restrictions.map(\.code), ["FormatRestrictedByFormatAvailability"])
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

    func testFileInfoCanRequestExactFormat7() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let requestBox = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            requestBox.set(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"url":"https://media.example/track.flac","format_id":7,"bit_depth":24,"sampling_rate":96}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: URLSession(configuration: configuration),
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero),
            timestamp: { 1_700_000_000 }
        )

        let info = try await client.fileInfo(trackID: QobuzID("123"), format: .hiRes96)

        XCTAssertEqual(info.format, .hiRes96)
        let request = try XCTUnwrap(requestBox.value)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["format_id"], "7")
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
        XCTAssertEqual(query["limit"], "30")
        XCTAssertEqual(query["offset"], "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "token")
    }

    func testSearchUsesRequestedOffsetAndReturnsQobuzCursorMetadata() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBox = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            requestBox.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"tracks":{"offset":30,"limit":30,"total":75,"items":[{"id":31,"title":"Page Two A","streamable":true,"purchasable":true},{"id":32,"title":"Page Two B","streamable":true,"purchasable":true}]}}"#
            return (response, Data(body.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: session,
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        let results = try await client.search("Sting", category: .tracks, limit: 30, offset: 30)

        XCTAssertEqual(results.tracks.map(\.title), ["Page Two A", "Page Two B"])
        XCTAssertEqual(results.offset, 30)
        XCTAssertEqual(results.nextOffset, 32)
        XCTAssertEqual(results.total, 75)
        let request = try XCTUnwrap(requestBox.value)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["limit"], "30")
        XCTAssertEqual(query["offset"], "30")
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
            let body = #"{"id":"f91ymo1s6vtgb","title":"Kids See Ghosts","subtitle":"Expanded edition","artist":{"id":243465,"name":"Kids See Ghosts"},"artists":[{"id":243465,"name":"Kids See Ghosts","roles":["main-artist"]},{"id":3764,"name":"Kanye West","roles":["main-artist"]},{"id":5409,"name":"Kid Cudi","roles":["main-artist"]}],"label":{"id":123,"name":"Getting Out Our Dreams","slug":"good"},"genre":{"name":"Hip-Hop"},"genres_list":["Hip-Hop","Alternative Hip-Hop"],"release_type":"ep","release_tags":["deluxe","remaster"],"is_official":true,"release_date_original":"2018-06-08","maximum_bit_depth":24,"maximum_sampling_rate":96,"maximum_channel_count":2,"catchline":"Qobuz editorial pick","description":"Album notes","awards":[{"id":88,"name":"Qobuzissime","awarded_at":"2018-06-15"}],"tracks":{"items":[]}}"#
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
        XCTAssertEqual(album.catalogMetadata.releaseType, .ep)
        XCTAssertEqual(album.catalogMetadata.releaseTags, ["deluxe", "remaster"])
        XCTAssertEqual(album.catalogMetadata.genres, ["Hip-Hop", "Alternative Hip-Hop"])
        XCTAssertEqual(album.catalogMetadata.isOfficial, true)
        XCTAssertEqual(album.catalogMetadata.subtitle, "Expanded edition")
        XCTAssertEqual(album.catalogMetadata.catchline, "Qobuz editorial pick")
        XCTAssertEqual(album.catalogMetadata.awards.first?.name, "Qobuzissime")
        XCTAssertEqual(album.catalogMetadata.audioCapabilities.maximumBitDepth, 24)
        XCTAssertEqual(album.catalogMetadata.audioCapabilities.maximumSamplingRate, 96)
        XCTAssertEqual(album.catalogMetadata.audioCapabilities.maximumChannelCount, 2)
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
            let body = #"{"id":52736446,"name":"Qobuz: The Power of Seven","description":"Playlist notes","duration":9201,"created_at":1768330514,"updated_at":1783719712,"tracks_count":35,"owner":{"id":922179,"name":"Qobuz"},"image":{"large":"https://static.qobuz.com/images/playlists/standard.jpg"},"image_rectangle":["https://static.qobuz.com/images/playlists/cover.jpg"],"tracks":{"items":[]}}"#
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
        XCTAssertEqual(playlist.catalogMetadata.artworkURL?.lastPathComponent, "standard.jpg")
        XCTAssertEqual(playlist.catalogMetadata.tracksCount, 35)
        XCTAssertEqual(playlist.catalogMetadata.editorialDescription, "Playlist notes")
    }

    func testHTTPFailureBodyIsBoundedBeforeItReachesErrorsAndLogs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let responseBody = String(repeating: "x", count: 2_000)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: URLSession(configuration: configuration),
            retryPolicy: QobuzRetryPolicy(maxAttempts: 1, baseDelay: .zero)
        )

        do {
            _ = try await client.search("failure", category: .tracks, limit: 30)
            XCTFail("Expected an HTTP failure")
        } catch NativeQobuzError.http(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message.count, 513)
            XCTAssertTrue(message.hasSuffix("… [truncated]"))
            XCTAssertFalse(message.contains(responseBody))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetryAfterHTTPDateControlsRetryDelay() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let attempts = LockedBox(0)
        let delays = LockedBox<[Duration]>([])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let retryAfter = formatter.string(from: Date().addingTimeInterval(3))
        StubURLProtocol.handler = { request in
            let attempt = attempts.value + 1
            attempts.set(attempt)
            if attempt == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": retryAfter]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"tracks":{"items":[]}}"#.utf8))
        }
        let client = QobuzAPIClient(
            credentials: QobuzCredentials(appID: "app", appSecret: "secret", authToken: "token"),
            session: URLSession(configuration: configuration),
            retryPolicy: QobuzRetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(1)),
            sleep: { delay in delays.set(delays.value + [delay]) }
        )

        _ = try await client.search("retry", category: .tracks, limit: 30)

        XCTAssertEqual(attempts.value, 2)
        let delay = try XCTUnwrap(delays.value.first)
        XCTAssertGreaterThan(delay, .zero)
        XCTAssertLessThanOrEqual(delay, .seconds(5))
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
