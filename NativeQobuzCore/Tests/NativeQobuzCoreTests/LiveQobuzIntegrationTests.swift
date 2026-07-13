import Foundation
import XCTest
@testable import NativeQobuzCore

final class LiveQobuzIntegrationTests: XCTestCase {
    func testFrenchAccountCanResolveAlbumAndSignedFileURL() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QOBUZ_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QOBUZ_INTEGRATION=1 and credential environment variables to run live Qobuz tests.")
        }
        let credentials = QobuzCredentials(
            appID: try required("QOBUZ_APP_ID", in: environment),
            appSecret: try required("QOBUZ_APP_SECRET", in: environment),
            authToken: try required("QOBUZ_AUTH_TOKEN", in: environment)
        )
        let albumID = QobuzID(environment["QOBUZ_TEST_ALBUM_ID"] ?? "je3x92urb9drs")
        let expectedRegion = environment["QOBUZ_EXPECTED_REGION"] ?? "FR"
        let client = QobuzAPIClient(credentials: credentials)

        let region = try await client.validateAccount()
        XCTAssertEqual(region, expectedRegion)

        let album = try await client.album(id: albumID)
        let firstTrack = try XCTUnwrap(album.tracks.first)
        XCTAssertFalse(album.title.isEmpty)
        XCTAssertFalse(album.tracks.isEmpty)

        let fileInfo = try await client.fileInfo(trackID: firstTrack.id, quality: .mp3)
        XCTAssertEqual(fileInfo.formatID, QobuzQuality.mp3.formatID)
        XCTAssertEqual(fileInfo.url.scheme, "https")

        let search = try await client.search("Adele 19", category: .albums, limit: 30)
        XCTAssertFalse(search.albums.isEmpty)
        XCTAssertTrue(search.albums.contains { $0.title.localizedCaseInsensitiveContains("19") })
    }

    func testFrenchAccountSearchFindsAdeleAcrossCategories() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QOBUZ_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QOBUZ_INTEGRATION=1 and credential environment variables to run live Qobuz tests.")
        }
        let client = QobuzAPIClient(credentials: try credentials(from: environment))

        async let albums = client.search("adele", category: .albums, limit: 30)
        async let artists = client.search("adele", category: .artists, limit: 30)
        async let tracks = client.search("adele", category: .tracks, limit: 30)
        let results = try await (albums, artists, tracks)

        XCTAssertTrue(results.0.albums.contains {
            $0.artist?.name.localizedCaseInsensitiveContains("adele") == true
        })
        XCTAssertTrue(results.0.albums.allSatisfy(\.streamable))
        XCTAssertTrue(results.1.artists.contains {
            $0.name.localizedCaseInsensitiveContains("adele")
        })
        XCTAssertTrue(results.2.tracks.contains {
            $0.performer?.name.localizedCaseInsensitiveContains("adele") == true
        })
        XCTAssertTrue(results.2.tracks.allSatisfy(\.streamable))
    }

    func testFrenchAccountPaginatesAdeleArtistCatalog() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QOBUZ_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QOBUZ_INTEGRATION=1 and credential environment variables to run live Qobuz tests.")
        }
        let client = QobuzAPIClient(credentials: try credentials(from: environment))
        let search = try await client.search("Adele", category: .artists, limit: 30)
        let adele = try XCTUnwrap(search.artists.first { $0.name.caseInsensitiveCompare("Adele") == .orderedSame })

        let catalog = try await client.artist(id: try XCTUnwrap(adele.id))

        XCTAssertGreaterThan(catalog.albums.count, 500)
        XCTAssertEqual(catalog.albums.count, catalog.albumsTotal)
        XCTAssertFalse(catalog.officialAlbums.isEmpty)
        XCTAssertFalse(catalog.appearanceAlbums.isEmpty)
        XCTAssertLessThan(catalog.officialAlbums.count, catalog.appearanceAlbums.count)
        XCTAssertTrue(catalog.officialAlbums.allSatisfy {
            catalog.relationship(of: $0) == .official && $0.streamable && $0.displayable
        })
        XCTAssertTrue(catalog.appearanceAlbums.allSatisfy {
            catalog.relationship(of: $0) == .appearance && $0.streamable && $0.displayable
        })
    }

    func testLiveSchemaPreservesMultipleAlbumArtistsLabelAndPlaylistMetadata() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QOBUZ_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QOBUZ_INTEGRATION=1 and credential environment variables to run live Qobuz tests.")
        }
        let client = QobuzAPIClient(credentials: try credentials(from: environment))

        let multiArtist = try await client.album(id: QobuzID("f91ymo1s6vtgb"))
        XCTAssertEqual(
            Set(multiArtist.mainArtists.map(\.name)),
            Set(["Kids See Ghosts", "Kanye West", "Kid Cudi"])
        )

        let label = try await client.label(id: QobuzID(environment["QOBUZ_TEST_LABEL_ID"] ?? "10278643"))
        XCTAssertFalse(label.name.isEmpty)
        XCTAssertFalse(label.albums.isEmpty)
        XCTAssertEqual(label.albums.count, label.albumsTotal)
        XCTAssertTrue(label.availableAlbums.allSatisfy { $0.accountAvailabilityIssue == nil })

        let playlist = try await client.playlist(
            id: QobuzID(environment["QOBUZ_TEST_PLAYLIST_ID"] ?? "52736446")
        )
        XCTAssertFalse(playlist.name.isEmpty)
        XCTAssertFalse(playlist.owner?.name.isEmpty ?? true)
        XCTAssertNotNil(playlist.createdAt)
        XCTAssertNotNil(playlist.updatedAt)
        XCTAssertNotNil(playlist.duration)
        XCTAssertNotNil(playlist.tracksCount)
        XCTAssertNotNil(playlist.playlistDescription)
        XCTAssertNotNil(playlist.artworkURL)
    }

    func testFrenchAccountCanTransferOneTrackToTemporaryFile() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QOBUZ_DOWNLOAD_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QOBUZ_DOWNLOAD_INTEGRATION=1 to run a temporary live audio transfer.")
        }
        let client = QobuzAPIClient(credentials: try credentials(from: environment))
        let albumID = QobuzID(environment["QOBUZ_TEST_ALBUM_ID"] ?? "je3x92urb9drs")
        let album = try await client.album(id: albumID)
        let track = try XCTUnwrap(album.tracks.first)
        let fileInfo = try await client.fileInfo(trackID: track.id, quality: .mp3)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeQobuzCore-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("transfer-test.mp3")
        defer { try? FileManager.default.removeItem(at: directory) }

        var sawProgress = false
        var completedURL: URL?
        for try await event in URLSessionFileTransferClient().events(from: fileInfo.url, to: destination) {
            switch event {
            case .progress(let progress):
                sawProgress = sawProgress || progress.bytesWritten > 0
            case .completed(let url):
                completedURL = url
            case .started:
                break
            }
        }

        XCTAssertTrue(sawProgress)
        XCTAssertEqual(completedURL, destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.int64Value ?? 0, 128 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
        let validator = try FFmpegMediaValidator.bundled()
        try await validator.validate(destination)
        let checksum = try MusicFileIntegrity.sha256(of: destination)
        XCTAssertEqual(checksum.count, 64)
        XCTAssertTrue(try MusicFileIntegrity.verify(destination, expectedSHA256: checksum))
    }

    private func credentials(from environment: [String: String]) throws -> QobuzCredentials {
        QobuzCredentials(
            appID: try required("QOBUZ_APP_ID", in: environment),
            appSecret: try required("QOBUZ_APP_SECRET", in: environment),
            authToken: try required("QOBUZ_AUTH_TOKEN", in: environment)
        )
    }

    private func required(_ key: String, in environment: [String: String]) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw XCTSkip("Missing \(key) for live Qobuz integration test.")
        }
        return value
    }
}
