import XCTest
@testable import NativeQobuzCore

final class MetadataWriterTests: XCTestCase {
    private let audioPayload = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4, 5, 6])

    func testQobuzMappingMatchesPluginArtistAndCreditBehavior() {
        let item = fixtureItem(
            performers: "Primary, MainArtist, Composer - Guest, FeaturedArtist - Engineer, Producer"
        )

        let metadata = QobuzAudioMetadata(item: item)

        XCTAssertEqual(metadata.artists, ["Primary", "Guest"])
        XCTAssertEqual(metadata.albumArtists, ["Primary", "Co-Headliner"])
        XCTAssertEqual(metadata.credits["Composer"], ["Primary"])
        XCTAssertEqual(metadata.credits["Producer"], ["Engineer"])
        XCTAssertNil(metadata.credits["MainArtist"])
    }

    func testCatalogOnlyMetadataCannotChangePortableAudioTags() {
        let baseline = QobuzAudioMetadata(item: fixtureItem())
        let catalogRich = QobuzAudioMetadata(item: fixtureItem(
            releaseType: .ep,
            releaseTags: ["deluxe", "remaster"],
            awards: [QobuzEditorialAward(id: QobuzID("88"), name: "Qobuzissime")]
        ))

        XCTAssertEqual(catalogRich, baseline)
    }

    func testMP3WriterUsesID3v23AndPreservesAudioAcrossRepeatedWrites() throws {
        let file = temporaryURL(extension: "mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try audioPayload.write(to: file)
        let writer = NativeAudioMetadataWriter()
        let metadata = QobuzAudioMetadata(item: fixtureItem())
        let artwork = EmbeddedArtwork(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg")

        try writer.write(metadata: metadata, artwork: artwork, to: file)
        try writer.write(metadata: metadata, artwork: artwork, to: file)

        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.prefix(6), Data([0x49, 0x44, 0x33, 3, 0, 0]))
        XCTAssertEqual(data.suffix(audioPayload.count), audioPayload)
        XCTAssertEqual(data.occurrences(of: Data("ID3".utf8)), 1)
        for frame in ["TIT2", "TALB", "TPE1", "TPE2", "TYER", "TDAT", "TRCK", "TPOS", "TSRC", "TPUB", "TCON", "TXXX", "APIC"] {
            XCTAssertTrue(data.contains(Data(frame.utf8)), "Missing \(frame)")
        }
    }

    func testFLACWriterReplacesCommentsAndPictureAndPreservesFrames() throws {
        let file = temporaryURL(extension: "flac")
        defer { try? FileManager.default.removeItem(at: file) }
        var source = Data("fLaC".utf8)
        source.append(contentsOf: [0x80, 0, 0, 34])
        source.append(Data(repeating: 0x11, count: 34))
        source.append(audioPayload)
        try source.write(to: file)
        let writer = NativeAudioMetadataWriter()
        let metadata = QobuzAudioMetadata(item: fixtureItem())
        let artwork = EmbeddedArtwork(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            width: 10,
            height: 12,
            depth: 24
        )

        try writer.write(metadata: metadata, artwork: artwork, to: file)
        try writer.write(metadata: metadata, artwork: artwork, to: file)

        let result = try Data(contentsOf: file)
        let blocks = try parseFLACBlocks(result)
        XCTAssertEqual(blocks.map(\.type), [0, 4, 6])
        XCTAssertEqual(result.suffix(audioPayload.count), audioPayload)
        let comments = String(decoding: blocks[1].payload, as: UTF8.self)
        for value in [
            "TITLE=Song", "ALBUM=Album", "ARTIST=Primary", "ALBUMARTIST=Primary",
            "ALBUMARTIST=Co-Headliner",
            "TRACKNUMBER=1", "TOTALTRACKS=2", "DISCNUMBER=1", "TOTALDISCS=1",
            "ISRC=FR123", "UPC=123456", "LABEL=Label", "RATING=Explicit"
        ] {
            XCTAssertTrue(comments.contains(value), "Missing \(value)")
        }
        XCTAssertTrue(blocks[2].payload.contains(Data("image/png".utf8)))
    }

    private func fixtureItem(
        performers: String? = nil,
        releaseType: QobuzReleaseType? = nil,
        releaseTags: [String] = [],
        awards: [QobuzEditorialAward] = []
    ) -> QobuzResolvedTrack {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Primary")
        let albumSummary = QobuzAlbumSummary(id: QobuzID("album"), title: "Album", artist: artist)
        let track = QobuzTrack(
            id: QobuzID("track"),
            title: "Song",
            performer: artist,
            composer: QobuzArtist(id: nil, name: "Writer"),
            album: albumSummary,
            duration: 120,
            trackNumber: 1,
            mediaNumber: 1,
            isrc: "FR123",
            performers: performers,
            parentalWarning: true
        )
        let album = QobuzAlbum(
            id: QobuzID("album"),
            title: "Album",
            artist: artist,
            artists: [
                QobuzArtistCredit(id: artist.id, name: artist.name, roles: ["main-artist"]),
                QobuzArtistCredit(id: QobuzID("co"), name: "Co-Headliner", roles: ["main-artist"])
            ],
            tracks: [track],
            tracksCount: 2,
            mediaCount: 1,
            releaseDate: "2025-04-03",
            genre: "Pop",
            releaseType: releaseType,
            releaseTags: releaseTags,
            label: "Label",
            awards: awards,
            copyright: "Copyright",
            upc: "123456",
            parentalWarning: true
        )
        return QobuzResolvedTrack(track: track, album: album, collection: .album(id: album.id, title: album.title), position: 1, total: 2)
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    private func parseFLACBlocks(_ data: Data) throws -> [(type: UInt8, payload: Data)] {
        guard data.starts(with: Data("fLaC".utf8)) else { throw TestError.invalidFLAC }
        var offset = 4
        var blocks: [(UInt8, Data)] = []
        var isLast = false
        while !isLast {
            guard offset + 4 <= data.count else { throw TestError.invalidFLAC }
            let typeByte = data[offset]
            isLast = typeByte & 0x80 != 0
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4
            guard offset + length <= data.count else { throw TestError.invalidFLAC }
            blocks.append((typeByte & 0x7F, data.subdata(in: offset..<(offset + length))))
            offset += length
        }
        return blocks
    }

    private enum TestError: Error { case invalidFLAC }
}

private extension Data {
    func occurrences(of needle: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(of: needle, options: [], in: searchStart..<endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
