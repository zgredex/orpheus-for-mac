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
            fileInfo: QobuzFileInfo(url: URL(string: "https://example.test/file.flac")!, format: .hiRes),
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

    func testMaximumQualityFallbackIsAnInformationalDeliveryNotice() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let trackID = try XCTUnwrap(album.tracks.first?.id)
        let fileInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/one.flac")!,
            format: .lossless,
            bitDepth: 16,
            samplingRate: 44.1,
            restrictions: [QobuzFileRestriction(code: "FormatRestrictedByFormatAvailability")]
        )
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(
                albums: [album.id: album],
                fileInfos: [trackID: fileInfo]
            ),
            transfer: FakeTransferClient(recorder: TransferRecorder()),
            validator: AcceptingValidator(format: .lossless),
            metadataWriter: RecordingMetadataWriter()
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var notices: [String] = []
        var warnings: [String] = []
        for try await event in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {
            if case .notice(let message) = event { notices.append(message) }
            if case .warning(let message) = event { warnings.append(message) }
        }

        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("Lossless FLAC delivered under the Hi-Res FLAC maximum"))
        XCTAssertTrue(warnings.isEmpty)
    }

    func testEngineRejectsDeliveryAboveCeilingBeforeStartingTransfer() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let trackID = try XCTUnwrap(album.tracks.first?.id)
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(
                albums: [album.id: album],
                fileInfos: [
                    trackID: QobuzFileInfo(
                        url: URL(string: "https://media.example/one.flac")!,
                        format: .hiRes96,
                        bitDepth: 24,
                        samplingRate: 96
                    )
                ]
            ),
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(format: .hiRes96),
            metadataWriter: RecordingMetadataWriter()
        )

        do {
            for try await _ in engine.events(for: .album(album.id), quality: .lossless, downloadRoot: root) {}
            XCTFail("Expected delivery above the lossless ceiling to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("above the configured Lossless FLAC maximum"))
        }

        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Artist/Album/01. One.flac").path
            )
        )
    }

    func testEngineRejectsInconsistentMediaBeforeInstallingOrRecordingProvenance() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let trackID = try XCTUnwrap(album.tracks.first?.id)
        let recorder = TransferRecorder()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(
                albums: [album.id: album],
                fileInfos: [
                    trackID: QobuzFileInfo(
                        url: URL(string: "https://media.example/one.flac")!,
                        format: .hiRes,
                        bitDepth: 24,
                        samplingRate: 96
                    )
                ]
            ),
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(
                properties: AudioStreamProperties(
                    container: .mp3,
                    codec: .mp3,
                    bitDepth: nil,
                    samplingRate: 44.1
                )
            ),
            metadataWriter: RecordingMetadataWriter()
        )

        do {
            for try await _ in engine.events(for: .album(album.id), quality: .hiRes, downloadRoot: root) {}
            XCTFail("Expected inconsistent downloaded media to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requires a FLAC container"))
        }

        let sourceCount = await recorder.sources.count
        XCTAssertEqual(sourceCount, 1)
        let finalAudio = root.appendingPathComponent("Artist/Album/01. One.flac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.path))
        XCTAssertNil(try QobuzCollectionAssetWriter().provenance(
            for: finalAudio,
            fileSystem: LibraryFileSystem(rootURL: root)
        ))
    }

    func testMaximumPolicyDownloadsEverySupportedDeliveredFormat() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let trackID = try XCTUnwrap(album.tracks.first?.id)

        for format in QobuzAudioFormat.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fileInfo = QobuzFileInfo(
                url: URL(string: "https://media.example/one.\(format.fileExtension)")!,
                format: format
            )
            let service = FakeQobuzService(
                albums: [album.id: album],
                fileInfos: [trackID: fileInfo]
            )
            let assetWriter = QobuzCollectionAssetWriter()
            let engine = NativeQobuzDownloadEngine(
                service: service,
                transfer: FakeTransferClient(recorder: TransferRecorder()),
                validator: AcceptingValidator(format: format),
                metadataWriter: RecordingMetadataWriter(),
                assetWriter: assetWriter
            )

            for try await _ in engine.events(
                for: .album(album.id),
                quality: .hiRes,
                downloadRoot: root
            ) {}

            let audioPaths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
                .filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == format.fileExtension }
            let relativePath = try XCTUnwrap(audioPaths.first)
            let audioURL = root.appendingPathComponent(relativePath)
            XCTAssertEqual(audioPaths.count, 1, "Delivered format \(format.formatID)")
            XCTAssertEqual(
                try assetWriter.provenance(
                    for: audioURL,
                    fileSystem: LibraryFileSystem(rootURL: root)
                )?.formatID,
                format.formatID,
                "Delivered format \(format.formatID)"
            )
            let requestedFormats = await service.fileInfoRequestedFormats
            XCTAssertEqual(requestedFormats, [.hiRes])
        }
    }

    func testEngineDownloadsOnlySelectedTracksAndReindexesProgress() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one", "two", "three"])
        let recorder = TransferRecorder()
        let engine = NativeQobuzDownloadEngine(
            service: FakeQobuzService(albums: [album.id: album]),
            transfer: FakeTransferClient(recorder: recorder),
            validator: AcceptingValidator(),
            metadataWriter: RecordingMetadataWriter()
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var events: [QobuzDownloadEvent] = []
        for try await event in engine.events(
            for: .album(album.id),
            quality: .hiRes,
            downloadRoot: root,
            includedTrackIDs: [QobuzID("two"), QobuzID("three")]
        ) {
            events.append(event)
        }

        let sources = await recorder.sources
        XCTAssertEqual(sources.map(\.lastPathComponent), ["two.flac", "three.flac"])
        XCTAssertTrue(events.contains(.planReady(title: "Album", trackCount: 2)))
        let started = events.compactMap { event -> QobuzResolvedTrack? in
            guard case .trackStarted(let track, _, _) = event else { return nil }
            return track
        }
        XCTAssertEqual(started.map(\.track.id), [QobuzID("two"), QobuzID("three")])
        XCTAssertEqual(started.map(\.position), [1, 2])
        XCTAssertEqual(started.map(\.total), [2, 2])
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
            format: .hiRes
        )
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(
                item: item,
                delivery: try validatedTestDelivery(for: fileInfo),
                sha256: String(repeating: "0", count: 64)
            ),
            for: destination,
            fileSystem: LibraryFileSystem(rootURL: root)
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
        XCTAssertNotNil(try QobuzCollectionAssetWriter().provenance(
            for: downloaded,
            fileSystem: LibraryFileSystem(rootURL: root)
        ))
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
            format: .hiRes
        )
        let checksum = try MusicFileIntegrity.sha256(of: destination)
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(
                item: item,
                delivery: try validatedTestDelivery(for: fileInfo),
                sha256: checksum
            ),
            for: destination,
            fileSystem: LibraryFileSystem(rootURL: root)
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
            format: .lossless
        )
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(
                item: item,
                delivery: try validatedTestDelivery(for: oldInfo),
                sha256: try MusicFileIntegrity.sha256(of: destination)
            ),
            for: destination,
            fileSystem: LibraryFileSystem(rootURL: root)
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
        let provenance = try XCTUnwrap(assetWriter.provenance(
            for: destination,
            fileSystem: LibraryFileSystem(rootURL: root)
        ))
        XCTAssertEqual(provenance.formatID, QobuzQuality.hiRes.maximumFormat.formatID)
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

    func testFormat7RepairRequestsExactArchivedFormatAndRewritesIntegrityRecords() async throws {
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
        let relativePath = "Repair Target/Unexpected Name.flac"
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: destination)
        let oldHash = String(repeating: "0", count: 64)
        let assetWriter = QobuzCollectionAssetWriter()
        try assetWriter.recordProvenance(
            QobuzFileProvenance(
                item: resolvedItem(for: album),
                delivery: try validatedTestDelivery(
                    for: QobuzFileInfo(
                        url: URL(string: "https://media.example/one.flac")!,
                        format: .hiRes96
                    )
                ),
                sha256: oldHash
            ),
            for: destination,
            fileSystem: LibraryFileSystem(rootURL: root)
        )
        let target = QobuzArchiveTrack(
            relativePath: relativePath,
            qobuzTrackID: "one",
            qobuzAlbumID: "album",
            formatID: QobuzAudioFormat.hiRes96.formatID,
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
            validator: AcceptingValidator(format: .hiRes96),
            metadataWriter: RecordingMetadataWriter(),
            assetWriter: assetWriter
        )

        for try await _ in try engine.repairEvents(for: target, downloadRoot: root) {}

        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Artist/One.flac").path))
        let repaired = try XCTUnwrap(assetWriter.provenance(
            for: destination,
            fileSystem: LibraryFileSystem(rootURL: root)
        ))
        let repairedHash = try MusicFileIntegrity.sha256(of: destination)
        XCTAssertEqual(repaired.sha256, repairedHash)
        XCTAssertEqual(repaired.formatID, QobuzAudioFormat.hiRes96.formatID)
        XCTAssertEqual(repaired.archiveKind, .album)
        let requestedFormats = await service.fileInfoRequestedFormats
        XCTAssertEqual(requestedFormats, [.hiRes96])
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
            formatID: QobuzQuality.hiRes.maximumFormat.formatID,
            expectedSHA256: String(repeating: "0", count: 64),
            integrity: .missing,
            archiveKind: .album
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
            integrity: .missing,
            archiveKind: .album
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

    func events(
        from source: URL,
        to destination: URL,
        fileSystem: LibraryFileSystem
    ) -> AsyncThrowingStream<FileTransferEvent, Error> {
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

    func events(
        from source: URL,
        to destination: URL,
        fileSystem: LibraryFileSystem
    ) -> AsyncThrowingStream<FileTransferEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(source)
                if let path = try? fileSystem.relativePath(for: destination) {
                    try? fileSystem.writeAtomically(Data([1, 2, 3]), to: path)
                }
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
    let properties: AudioStreamProperties

    init(format: QobuzAudioFormat = .hiRes) {
        properties = testAudioProperties(for: format)
    }

    init(properties: AudioStreamProperties) {
        self.properties = properties
    }

    func validate(
        _ fileURL: URL,
        fileSystem: LibraryFileSystem
    ) async throws -> AudioStreamProperties {
        properties
    }
}

struct RecordingMetadataWriter: AudioMetadataWriting {
    func write(
        metadata: QobuzAudioMetadata,
        artwork: EmbeddedArtwork?,
        to fileURL: URL,
        fileSystem: LibraryFileSystem
    ) throws {}
}

private struct FailingAssetFetcher: QobuzAssetFetching {
    func fetch(_ url: URL) async throws -> QobuzAssetResponse {
        throw NativeQobuzError.network("Fixture asset failure")
    }
}
