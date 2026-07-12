import Foundation
import XCTest
@testable import NativeQobuzCore

final class DownloadEngineTests: XCTestCase {
    func testOutputPlannerSanitizesPathsAndUsesDiscPrefix() {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist/Name")
        let track = QobuzTrack(
            id: QobuzID("track"),
            title: "Track: Name",
            performer: artist,
            trackNumber: 2,
            mediaNumber: 2
        )
        let album = QobuzAlbum(
            id: QobuzID("album"),
            title: "Album/Name",
            artist: artist,
            tracks: [track],
            tracksCount: 12,
            mediaCount: 2
        )
        let item = QobuzResolvedTrack(
            track: track,
            album: album,
            collection: .album(id: album.id, title: album.title),
            position: 2,
            total: 12
        )
        let destination = StandardQobuzOutputPlanner().destination(
            for: item,
            fileInfo: QobuzFileInfo(url: URL(string: "https://example.test/file.flac")!, formatID: 27),
            root: URL(fileURLWithPath: "/downloads")
        )

        XCTAssertEqual(destination.path, "/downloads/Artist_Name/Album_Name/2-02. Track_ Name.flac")
    }

    func testEngineRunsSequentiallyAndAggregatesFileProgressAcrossTracks() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one", "two"])
        let service = FakeQobuzService(albums: [album.id: album])
        let recorder = TransferRecorder()
        let transfer = FakeTransferClient(recorder: recorder)
        let engine = NativeQobuzDownloadEngine(service: service, transfer: transfer)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var events: [QobuzDownloadEvent] = []
        for try await event in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {
            events.append(event)
        }

        let sources = await recorder.sources
        XCTAssertEqual(sources.map(\.lastPathComponent), ["one.flac", "two.flac"])
        let fractions = events.compactMap { event -> Double? in
            guard case .progress(let progress) = event else { return nil }
            return progress.overallFraction
        }
        let expected = [0.25, 0.5, 0.75, 1.0]
        XCTAssertEqual(fractions.count, expected.count)
        for (actual, expected) in zip(fractions, expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertTrue(events.contains(.completed(title: "Album", downloaded: 2, skipped: 0)))
    }
}

actor TransferRecorder {
    private(set) var sources: [URL] = []
    func record(_ source: URL) { sources.append(source) }
}

struct FakeTransferClient: FileTransferClient {
    let recorder: TransferRecorder

    func events(from source: URL, to destination: URL) -> AsyncThrowingStream<FileTransferEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(source)
                continuation.yield(.started)
                continuation.yield(
                    .progress(
                        FileTransferProgress(
                            bytesWritten: 50,
                            totalBytes: 100,
                            bytesPerSecond: 10
                        )
                    )
                )
                continuation.yield(.completed(destination))
                continuation.finish()
            }
        }
    }
}
