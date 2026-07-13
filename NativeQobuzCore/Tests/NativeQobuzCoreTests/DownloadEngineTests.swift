import Foundation
import XCTest
@testable import NativeQobuzCore

final class DownloadEngineTests: XCTestCase {
    func testDownloadArtifactsExposeTheResumablePartialPath() {
        let destination = URL(fileURLWithPath: "/downloads/Artist/Album/01. Track.flac")

        XCTAssertEqual(
            QobuzDownloadArtifacts.processingURL(for: destination, formatID: 27).path,
            "/downloads/Artist/Album/.01. Track.qobuz-27.processing.flac"
        )
        XCTAssertEqual(
            QobuzDownloadArtifacts.partialURL(for: destination, formatID: 27).path,
            "/downloads/Artist/Album/.01. Track.qobuz-27.processing.flac.partial"
        )
    }

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
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: transfer,
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )
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

    func testEachRestartReacquiresAFreshSignedFileURL() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let service = FakeQobuzService(albums: [album.id: album])
        let recorder = TransferRecorder()
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )
        let firstRoot = temporaryDirectory()
        let secondRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        for try await _ in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: firstRoot) {}
        for try await _ in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: secondRoot) {}

        let fileInfoRequestCount = await service.fileInfoRequestCount
        XCTAssertEqual(fileInfoRequestCount, 2)
        let sources = await recorder.sources
        XCTAssertEqual(sources.count, 2)
        XCTAssertNotEqual(sources[0], sources[1])
    }

    func testPlaylistReusesCanonicalAlbumAudioAndAddsLogicalLibraryMembership() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let summary = QobuzAlbumSummary(id: album.id, title: album.title, artist: album.artist)
        let playlistTrack = QobuzTrack(
            id: QobuzID("one"),
            title: "One",
            performer: album.artist,
            album: summary,
            duration: 120,
            trackNumber: 1,
            mediaNumber: 1
        )
        let playlist = QobuzPlaylist(
            id: QobuzID("playlist"),
            name: "Favorites",
            tracks: [playlistTrack],
            owner: QobuzPlaylistOwner(name: "Curator")
        )
        let service = FakeQobuzService(
            albums: [album.id: album],
            playlists: [playlist.id: playlist]
        )
        let recorder = TransferRecorder()
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for try await _ in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {}
        for try await _ in engine.events(for: .playlist(playlist.id), quality: .hiRes, downloadRoot: root) {}

        let transferCount = await recorder.sources.count
        XCTAssertEqual(transferCount, 1)
        let manifest = try QobuzLibraryManifestIO.load(at: root)
        XCTAssertEqual(Set(manifest.collections.map(\.id)), Set(["album|album", "playlist|playlist"]))
        XCTAssertEqual(Set(manifest.collections.flatMap(\.trackPaths)).count, 1)
        let audioFiles = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { ["flac", "mp3"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        XCTAssertEqual(audioFiles.count, 1)
        let m3u = root.appendingPathComponent("Playlists/Favorites [playlist]/Favorites.m3u")
        XCTAssertTrue(try String(contentsOf: m3u, encoding: .utf8).contains("../../Artist/Album/01. One.flac"))
    }

    func testDifferentFLACQualitiesCannotShareAPartialFile() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let recorder = DestinationRecorder()
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(albums: [album.id: album]),
            transfer: FailingTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for quality in [QobuzQuality.lossless, .hiRes] {
            do {
                for try await _ in engine.events(for: .album(album.id), quality: quality, downloadRoot: root) {}
                XCTFail("Expected fixture transfer failure")
            } catch {}
        }

        let destinations = await recorder.destinations
        XCTAssertEqual(destinations.count, 2)
        XCTAssertNotEqual(destinations[0], destinations[1])
        XCTAssertTrue(destinations[0].lastPathComponent.contains("qobuz-6"))
        XCTAssertTrue(destinations[1].lastPathComponent.contains("qobuz-27"))
    }

    func testEngineReplacesChecksumMismatchedExistingFileEvenWhenDecoderAcceptsIt() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let service = FakeQobuzService(albums: [album.id: album])
        let recorder = TransferRecorder()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Artist/Album/01. One.flac")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("decodable but modified".utf8).write(to: destination)
        try Data("\(String(repeating: "0", count: 64))  01. One.flac\n".utf8).write(
            to: destination.deletingLastPathComponent().appendingPathComponent("checksums.sha256")
        )
        let item = resolvedItem(for: album)
        let fileInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/one.flac")!,
            formatID: QobuzQuality.hiRes.formatID
        )
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(item: item, fileInfo: fileInfo, sha256: String(repeating: "0", count: 64)),
            for: destination
        )
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter(),
            assetWriter: assetWriter
        )

        var events: [QobuzDownloadEvent] = []
        for try await event in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {
            events.append(event)
        }

        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertTrue(events.contains(.completed(title: "Album", downloaded: 1, skipped: 0)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("checksums.sha256").path))
    }

    func testEnginePreservesUnidentifiedExistingFileAndUsesTrackIDSuffix() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let service = FakeQobuzService(albums: [album.id: album])
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Artist/Album/01. One.flac")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userData = Data("unidentified user file".utf8)
        try userData.write(to: original)
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )

        for try await _ in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {}

        let downloaded = original.deletingLastPathComponent().appendingPathComponent("01. One [one].flac")
        XCTAssertEqual(try Data(contentsOf: original), userData)
        XCTAssertEqual(try Data(contentsOf: downloaded), Data([1, 2, 3]))
        XCTAssertNotNil(try QobuzCollectionAssetWriter().provenance(for: downloaded))
        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 1)
    }

    func testEngineSkipsOnlyWhenIdentityQualityAndChecksumMatch() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let service = FakeQobuzService(albums: [album.id: album])
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Artist/Album/01. One.flac")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: destination)
        let item = resolvedItem(for: album)
        let fileInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/one.flac")!,
            formatID: QobuzQuality.hiRes.formatID
        )
        let checksum = try MusicFileIntegrity.sha256(of: destination)
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(item: item, fileInfo: fileInfo, sha256: checksum),
            for: destination
        )
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter(),
            assetWriter: assetWriter
        )

        var events: [QobuzDownloadEvent] = []
        for try await event in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {
            events.append(event)
        }

        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 0)
        XCTAssertTrue(events.contains(.completed(title: "Album", downloaded: 0, skipped: 1)))
    }

    func testEngineRedownloadsSameTrackWhenRequestedQualityChanges() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let service = FakeQobuzService(albums: [album.id: album])
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Artist/Album/01. One.flac")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old quality".utf8).write(to: destination)
        let item = resolvedItem(for: album)
        let oldInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/one.flac")!,
            formatID: QobuzQuality.lossless.formatID
        )
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(
                item: item,
                fileInfo: oldInfo,
                sha256: try MusicFileIntegrity.sha256(of: destination)
            ),
            for: destination
        )
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter(),
            assetWriter: assetWriter
        )

        for try await _ in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {}

        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        let provenance = try XCTUnwrap(assetWriter.provenance(for: destination))
        XCTAssertEqual(provenance.formatID, QobuzQuality.hiRes.formatID)
        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 1)
    }

    func testBookletFailureWarnsButKeepsCompletedAudio() async throws {
        let base = makeAlbum(id: "album", trackIDs: ["one"])
        let album = QobuzAlbum(
            id: base.id,
            title: base.title,
            artist: base.artist,
            tracks: base.tracks,
            tracksCount: base.tracksCount,
            mediaCount: base.mediaCount,
            releaseDate: base.releaseDate,
            bookletURL: URL(string: "https://assets.example/booklet.pdf")!
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(albums: [album.id: album]),
            transfer: FakeTransferClient(recorder: TransferRecorder()),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter(),
            assetWriter: QobuzCollectionAssetWriter(fetcher: FailingAssetFetcher())
        )

        var events: [QobuzDownloadEvent] = []
        for try await event in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            guard case .warning(let message) = event else { return false }
            return message.contains("Booklet")
        })
        XCTAssertTrue(events.contains(.completed(title: "Album", downloaded: 1, skipped: 0)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Artist/Album/01. One.flac").path))
    }

    func testRepairReplacesOnlyTheExactArchivedPathAndRewritesIntegrityRecords() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let summary = QobuzAlbumSummary(id: album.id, title: album.title, artist: album.artist)
        let track = QobuzTrack(
            id: QobuzID("one"),
            title: "One",
            performer: album.artist,
            album: summary,
            trackNumber: 1,
            mediaNumber: 1
        )
        let service = FakeQobuzService(tracks: [track.id: track], albums: [album.id: album])
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "Legacy Folder/Unexpected Name.flac"
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: destination)
        let oldHash = String(repeating: "0", count: 64)
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(
                item: resolvedItem(for: album),
                fileInfo: QobuzFileInfo(
                    url: URL(string: "https://media.example/one.flac")!,
                    formatID: QobuzQuality.hiRes.formatID
                ),
                sha256: oldHash
            ),
            for: destination
        )
        let target = QobuzArchiveTrack(
            relativePath: relativePath,
            qobuzTrackID: "one",
            qobuzAlbumID: "album",
            formatID: QobuzQuality.hiRes.formatID,
            bitDepth: 24,
            samplingRate: 96,
            expectedSHA256: oldHash,
            actualSHA256: try MusicFileIntegrity.sha256(of: destination),
            byteCount: 7,
            integrity: .checksumMismatch,
            archiveKind: .album
        )
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter(),
            assetWriter: assetWriter
        )

        for try await _ in try engine.repairEvents(for: target, downloadRoot: root) {}

        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Artist/One.flac").path))
        let repaired = try XCTUnwrap(assetWriter.provenance(for: destination))
        let repairedHash = try MusicFileIntegrity.sha256(of: destination)
        XCTAssertEqual(repaired.sha256, repairedHash)
        XCTAssertEqual(repaired.formatID, QobuzQuality.hiRes.formatID)
        XCTAssertEqual(repaired.archiveKind, .album)
        let checksumManifest = try String(
            contentsOf: destination.deletingLastPathComponent().appendingPathComponent("checksums.sha256"),
            encoding: .utf8
        )
        XCTAssertTrue(checksumManifest.contains("\(repairedHash)  \(destination.lastPathComponent)"))
        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 1)
    }

    func testRepairRefusesAStaleManifestBeforeTransferring() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let summary = QobuzAlbumSummary(id: album.id, title: album.title, artist: album.artist)
        let track = QobuzTrack(id: QobuzID("one"), title: "One", performer: album.artist, album: summary)
        let service = FakeQobuzService(tracks: [track.id: track], albums: [album.id: album])
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Album"), withIntermediateDirectories: true)
        let target = QobuzArchiveTrack(
            relativePath: "Album/01.flac",
            qobuzTrackID: "one",
            qobuzAlbumID: "album",
            formatID: QobuzQuality.hiRes.formatID,
            expectedSHA256: String(repeating: "0", count: 64),
            integrity: .missing
        )
        let engine = NativeQobuzDownloadEngine(
            service: service,
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )

        do {
            for try await _ in try engine.repairEvents(for: target, downloadRoot: root) {}
            XCTFail("Expected stale provenance to stop repair")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("archive record changed"))
        }
        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 0)
    }

    func testRepairRejectsUnknownArchivedFormat() throws {
        let target = QobuzArchiveTrack(
            relativePath: "Album/01.flac",
            qobuzTrackID: "one",
            qobuzAlbumID: "album",
            formatID: 999,
            expectedSHA256: String(repeating: "0", count: 64),
            integrity: .missing
        )
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(),
            validator: AcceptingValidator()
        )

        XCTAssertThrowsError(try engine.repairEvents(for: target, downloadRoot: temporaryDirectory()))
    }

    private func resolvedItem(for album: QobuzAlbum) -> QobuzResolvedTrack {
        QobuzResolvedTrack(
            track: album.tracks[0],
            album: album,
            collection: .album(id: album.id, title: album.title),
            position: 1,
            total: 1
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

actor TransferRecorder {
    private(set) var sources: [URL] = []
    func record(_ source: URL) { sources.append(source) }
}

actor DestinationRecorder {
    private(set) var destinations: [URL] = []
    func record(_ destination: URL) { destinations.append(destination) }
}

struct FailingTransferClient: FileTransferClient {
    let recorder: DestinationRecorder

    func events(from source: URL, to destination: URL) -> AsyncThrowingStream<FileTransferEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(destination)
                continuation.finish(throwing: NativeQobuzError.network("Fixture interruption"))
            }
        }
    }
}

struct FakeTransferClient: FileTransferClient {
    let recorder: TransferRecorder

    func events(from source: URL, to destination: URL) -> AsyncThrowingStream<FileTransferEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(source)
                try? FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? Data([1, 2, 3]).write(to: destination)
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

struct AcceptingValidator: MediaValidating {
    func validate(_ fileURL: URL) async throws {}
}

struct RecordingMetadataWriter: AudioMetadataWriting {
    func write(metadata: QobuzAudioMetadata, artwork: EmbeddedArtwork?, to fileURL: URL) throws {}
}

private struct FailingAssetFetcher: QobuzAssetFetching {
    func fetch(_ url: URL) async throws -> QobuzAssetResponse {
        throw NativeQobuzError.network("Fixture asset failure")
    }
}
