import XCTest
@testable import NativeQobuzCore

final class CollectionAssetTests: XCTestCase {
    func testArtworkUsesOriginalQobuzURLAndSavesAlbumCover() async throws {
        let item = makeItem(collection: .album(id: QobuzID("album"), title: "Album"))
        let expected = URL(string: "https://static.qobuz.com/images/covers/ab/cd/cover_org.jpg")!
        let image = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let writer = QobuzCollectionAssetWriter(
            fetcher: FixtureAssetFetcher(responses: [expected: .init(data: image, mimeType: "image/jpeg")])
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Artist/Album/01. Song.flac")

        let artwork = try await writer.artwork(for: item.album)
        let cover = try XCTUnwrap(writer.saveExternalArtwork(try XCTUnwrap(artwork), for: item, audioURL: audio))

        XCTAssertEqual(cover.lastPathComponent, "cover.png")
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

    func testAlbumDescriptionIsWrittenForAlbumCatalogDownloads() throws {
        let item = makeItem(
            collection: .artist(id: QobuzID("artist"), name: "Primary"),
            albumDescription: "  Qobuz editorial notes.  "
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Primary/Album/01. Song.flac")

        let files = try QobuzCollectionAssetWriter().writeAlbumDescriptions(for: [(item, audio)])

        XCTAssertEqual(files, [audio.deletingLastPathComponent().appendingPathComponent("description.txt")])
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "Qobuz editorial notes.")
    }

    func testPlaylistDoesNotCreateMisleadingSourceAlbumDescription() throws {
        let item = makeItem(
            collection: .playlist(id: QobuzID("playlist"), title: "Mix"),
            albumDescription: "Album notes"
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Primary/Album/01. Song.flac")

        XCTAssertTrue(try QobuzCollectionAssetWriter().writeAlbumDescriptions(for: [(item, audio)]).isEmpty)
    }

    func testPlaylistWritesExtendedRelativeM3U() throws {
        let item = makeItem(collection: .playlist(id: QobuzID("playlist"), title: "Road Trip"))
        let plan = QobuzDownloadPlan(request: .playlist(QobuzID("playlist")), title: "Road Trip", tracks: [item])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Road Trip/01. Primary - Song.mp3")

        let playlist = try XCTUnwrap(
            QobuzCollectionAssetWriter().writePlaylist(plan: plan, outputs: [(item, audio)], downloadRoot: root)
        )
        let contents = try String(contentsOf: playlist, encoding: .utf8)

        XCTAssertEqual(playlist.lastPathComponent, "Road Trip.m3u")
        XCTAssertTrue(contents.contains("#EXTM3U"))
        XCTAssertTrue(contents.contains("#EXTINF:120, Primary - Song"))
        XCTAssertTrue(contents.contains("01. Primary - Song.mp3"))
        XCTAssertFalse(contents.contains(root.path))
    }

    func testLibraryManifestKeepsRichPlaylistMetadataAndPortableTrackPaths() throws {
        let item = makeItem(collection: .playlist(id: QobuzID("playlist"), title: "Road Trip"))
        let playlist = QobuzPlaylist(
            id: QobuzID("playlist"),
            name: "Road Trip",
            tracks: [item.track],
            owner: QobuzPlaylistOwner(id: QobuzID("owner"), name: "Curator"),
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_120,
            duration: 120,
            description: "A portable mix",
            tracksCount: 8
        )
        let plan = QobuzDownloadPlan(
            request: .playlist(playlist.id),
            title: playlist.name,
            tracks: [item],
            source: .playlist(playlist)
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Primary/Album/01. Song.mp3")
        let writer = QobuzCollectionAssetWriter()

        let m3u = try XCTUnwrap(writer.writePlaylist(plan: plan, outputs: [(item, audio)], downloadRoot: root))
        _ = try writer.recordLibraryCollections(plan: plan, outputs: [(item, audio)], downloadRoot: root)
        let manifest = try QobuzLibraryManifestIO.load(at: root)

        let record = try XCTUnwrap(manifest.collections.first)
        XCTAssertEqual(record.id, "playlist|playlist")
        XCTAssertEqual(record.owner, "Curator")
        XCTAssertEqual(record.collectionDescription, "A portable mix")
        XCTAssertEqual(record.createdAt, 1_700_000_000)
        XCTAssertEqual(record.updatedAt, 1_700_000_120)
        XCTAssertEqual(record.duration, 120)
        XCTAssertEqual(record.sourceTrackCount, 8)
        XCTAssertEqual(record.trackPaths, ["Primary/Album/01. Song.mp3"])
        let contents = try String(contentsOf: m3u, encoding: .utf8)
        XCTAssertTrue(contents.contains("../../Primary/Album/01. Song.mp3"))
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
            format: .hiRes,
            bitDepth: 24,
            samplingRate: 96
        )
        let provenance = QobuzFileProvenance(
            item: item,
            delivery: try validatedTestDelivery(for: fileInfo),
            sha256: try MusicFileIntegrity.sha256(of: audio)
        )
        let writer = QobuzCollectionAssetWriter()

        try writer.recordProvenance(provenance, for: audio)

        XCTAssertEqual(try writer.provenance(for: audio), provenance)
        XCTAssertTrue(provenance.belongs(to: item))
        XCTAssertTrue(provenance.matches(item: item, delivery: try validatedTestDelivery(for: fileInfo)))
        let encoded = try JSONEncoder().encode(provenance)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys)
        XCTAssertEqual(keys, [
            "qobuzTrackID", "qobuzAlbumID", "formatID", "bitDepth", "samplingRate",
            "sha256", "archiveKind", "isLibraryManaged"
        ])
        XCTAssertFalse(
            provenance.matches(
                item: item,
                delivery: try validatedTestDelivery(
                    for: QobuzFileInfo(
                        url: fileInfo.url,
                        format: .lossless,
                        bitDepth: 16,
                        samplingRate: 44.1
                    )
                )
            )
        )
    }

    private func makeItem(
        collection: QobuzCollection,
        bookletURL: URL? = nil,
        albumDescription: String? = nil
    ) -> QobuzResolvedTrack {
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
            albumDescription: albumDescription,
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
