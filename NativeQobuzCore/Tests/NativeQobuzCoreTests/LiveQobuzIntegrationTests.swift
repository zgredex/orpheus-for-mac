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
