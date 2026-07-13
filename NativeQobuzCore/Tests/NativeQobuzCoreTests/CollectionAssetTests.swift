import XCTest
@testable import NativeQobuzCore

final class CollectionAssetTests: XCTestCase {
    func testArtworkUsesOriginalQobuzURLAndSavesAlbumCover() async throws {
        let item = makeItem(collection: .album(id: QobuzID("album"), title: "Album"))
        let expected = URL(string: "https://static.qobuz.com/images/covers/ab/cd/cover_org.jpg")!
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let writer = QobuzCollectionAssetWriter(
            fetcher: FixtureAssetFetcher(responses: [expected: .init(data: image, mimeType: "image/jpeg")])
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Artist/Album/01. Song.flac")

        let artwork = try await writer.artwork(for: item.album)
        let cover = try XCTUnwrap(writer.saveExternalArtwork(try XCTUnwrap(artwork), for: item, audioURL: audio))

        XCTAssertEqual(cover.lastPathComponent, "cover.jpg")
        XCTAssertEqual(try Data(contentsOf: cover), image)
    }

    func testBookletRequiresPDFAndWritesOncePerAlbum() async throws {
        let bookletURL = URL(string: "https://static.qobuz.com/booklet.pdf")!
        let item = makeItem(
            collection: .album(id: QobuzID("album"), title: "Album"),
            bookletURL: bookletURL
        )
        let pdf = Data("%PDF-1.7\ntest".utf8)
        let writer = QobuzCollectionAssetWriter(
            fetcher: FixtureAssetFetcher(responses: [bookletURL: .init(data: pdf, mimeType: "application/pdf")])
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Artist/Album/01. Song.flac")
        let second = root.appendingPathComponent("Artist/Album/02. Song.flac")

        let files = try await writer.downloadBooklets(for: [(item, first), (item, second)])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "Booklet.pdf")
        XCTAssertEqual(try Data(contentsOf: files[0]), pdf)
    }

    func testPlaylistWritesExtendedRelativeM3U() throws {
        let item = makeItem(collection: .playlist(id: QobuzID("playlist"), title: "Road Trip"))
        let plan = QobuzDownloadPlan(request: .playlist(QobuzID("playlist")), title: "Road Trip", tracks: [item])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Road Trip/01. Primary - Song.mp3")

        let playlist = try XCTUnwrap(
            QobuzCollectionAssetWriter().writePlaylist(plan: plan, outputs: [(item, audio)])
        )
        let contents = try String(contentsOf: playlist, encoding: .utf8)

        XCTAssertEqual(playlist.lastPathComponent, "Road Trip.m3u")
        XCTAssertTrue(contents.contains("#EXTM3U"))
        XCTAssertTrue(contents.contains("#EXTINF:120, Primary - Song"))
        XCTAssertTrue(contents.contains("01. Primary - Song.mp3"))
        XCTAssertFalse(contents.contains(root.path))
    }

    func testChecksumManifestUsesFinalFileHashAndCanDetectChanges() throws {
        let item = makeItem(collection: .album(id: QobuzID("album"), title: "Album"))
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Artist/Album/01. Song.flac")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: audio)
        let checksum = try MusicFileIntegrity.sha256(of: audio)
        let oldHash = String(repeating: "1", count: 64)
        let manifest = audio.deletingLastPathComponent().appendingPathComponent("checksums.sha256")
        try Data("\(oldHash)  older.flac\n".utf8).write(to: manifest)

        let manifests = try QobuzCollectionAssetWriter().writeChecksumManifests(
            for: [(item, audio, checksum)]
        )

        XCTAssertEqual(checksum, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(try MusicFileIntegrity.verify(audio, expectedSHA256: checksum))
        let manifestContents = try String(contentsOf: manifests[0], encoding: .utf8)
        XCTAssertTrue(manifestContents.contains("\(checksum)  01. Song.flac\n"))
        XCTAssertTrue(manifestContents.contains("\(oldHash)  older.flac\n"))
        XCTAssertEqual(try QobuzCollectionAssetWriter().expectedChecksum(for: audio), checksum)
        try Data("changed".utf8).write(to: audio)
        XCTAssertFalse(try MusicFileIntegrity.verify(audio, expectedSHA256: checksum))
    }

    func testProvenanceRoundTripRecordsIdentityQualityAndIntegrity() throws {
        let item = makeItem(collection: .album(id: QobuzID("album"), title: "Album"))
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Artist/Album/01. Song.flac")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audio)
        let fileInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/song.flac")!,
            formatID: 27,
            bitDepth: 24,
            samplingRate: 96
        )
        let provenance = QobuzFileProvenance(
            item: item,
            fileInfo: fileInfo,
            sha256: try MusicFileIntegrity.sha256(of: audio)
        )
        let writer = QobuzCollectionAssetWriter()

        try writer.recordProvenance(provenance, for: audio)

        XCTAssertEqual(try writer.provenance(for: audio), provenance)
        XCTAssertTrue(provenance.belongs(to: item))
        XCTAssertTrue(provenance.matches(item: item, fileInfo: fileInfo))
        XCTAssertFalse(
            provenance.matches(
                item: item,
                fileInfo: QobuzFileInfo(url: fileInfo.url, formatID: 6, bitDepth: 16, samplingRate: 44.1)
            )
        )
    }

    private func makeItem(collection: QobuzCollection, bookletURL: URL? = nil) -> QobuzResolvedTrack {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Primary")
        let image = QobuzImage(large: URL(string: "https://static.qobuz.com/images/covers/ab/cd/cover_600.jpg"))
        let summary = QobuzAlbumSummary(id: QobuzID("album"), title: "Album", artist: artist, image: image)
        let track = QobuzTrack(
            id: QobuzID("track"),
            title: "Song",
            performer: artist,
            album: summary,
            duration: 120,
            trackNumber: 1,
            mediaNumber: 1
        )
        let album = QobuzAlbum(
            id: QobuzID("album"),
            title: "Album",
            artist: artist,
            image: image,
            tracks: [track],
            tracksCount: 1,
            mediaCount: 1,
            bookletURL: bookletURL
        )
        return QobuzResolvedTrack(track: track, album: album, collection: collection, position: 1, total: 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct FixtureAssetFetcher: QobuzAssetFetching {
    let responses: [URL: QobuzAssetResponse]

    func fetch(_ url: URL) async throws -> QobuzAssetResponse {
        guard let response = responses[url] else {
            throw NativeQobuzError.unavailable("Unexpected asset URL: \(url)")
        }
        return response
    }
}
