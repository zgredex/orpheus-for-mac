import Foundation
import XCTest
@testable import NativeQobuzCore

final class ArchiveScannerSymlinkTests: XCTestCase {
    func testArtistDirectorySymlinkIsReportedWithoutScanningTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalArtist = try fixture.externalDirectory("Artist/Album")
        try fixture.writeArchive(in: externalArtist)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Artist"),
            withDestinationURL: fixture.external.appendingPathComponent("Artist")
        )

        let snapshot = try await QobuzArchiveScanner().scan(root: fixture.root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertTrue(snapshot.issues.contains { $0.relativePath == "Artist" })
    }

    func testAlbumDirectorySymlinkIsReportedWithoutScanningTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artist = try fixture.libraryDirectory("Artist")
        let externalAlbum = try fixture.externalDirectory("Album")
        try fixture.writeArchive(in: externalAlbum)
        try FileManager.default.createSymbolicLink(
            at: artist.appendingPathComponent("Album"),
            withDestinationURL: externalAlbum
        )

        let snapshot = try await QobuzArchiveScanner().scan(root: fixture.root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertTrue(snapshot.issues.contains { $0.relativePath == "Artist/Album" })
    }

    func testAudioFileSymlinkIsUnreadableAndTargetIsNeverHashed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let album = try fixture.libraryDirectory("Artist/Album")
        let externalAudio = fixture.external.appendingPathComponent("outside.flac")
        try Data("outside audio must not be opened".utf8).write(to: externalAudio)
        try FileManager.default.createSymbolicLink(
            at: album.appendingPathComponent("01. Track.flac"),
            withDestinationURL: externalAudio
        )
        try fixture.writeManifest(in: album, filename: "01. Track.flac")

        let snapshot = try await QobuzArchiveScanner().scan(root: fixture.root)
        let track = try XCTUnwrap(snapshot.tracks.first)

        XCTAssertEqual(track.integrity, .unreadable)
        XCTAssertNil(track.actualSHA256)
        XCTAssertTrue(snapshot.issues.contains { $0.relativePath == "Artist/Album/01. Track.flac" })
    }

    func testManifestSymlinkIsReportedWithoutDecodingOrHashingTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let album = try fixture.libraryDirectory("Artist/Album")
        let externalAlbum = try fixture.externalDirectory("ExternalAlbum")
        try fixture.writeArchive(in: externalAlbum)
        try FileManager.default.createSymbolicLink(
            at: album.appendingPathComponent(QobuzProvenanceManifestIO.filename),
            withDestinationURL: externalAlbum.appendingPathComponent(QobuzProvenanceManifestIO.filename)
        )

        let snapshot = try await QobuzArchiveScanner().scan(root: fixture.root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertTrue(snapshot.issues.contains {
            $0.relativePath == "Artist/Album/\(QobuzProvenanceManifestIO.filename)"
        })
    }
}

private extension ArchiveScannerSymlinkTests {
    struct Fixture {
        let parent: URL
        let root: URL
        let external: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrpheusScannerSymlinkTests-\(UUID().uuidString)", isDirectory: true)
            root = parent.appendingPathComponent("Library", isDirectory: true)
            external = parent.appendingPathComponent("External", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }

        func libraryDirectory(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func externalDirectory(_ relativePath: String) throws -> URL {
            let url = external.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func writeArchive(in folder: URL) throws {
            try Data("external audio".utf8).write(to: folder.appendingPathComponent("01. Track.flac"))
            try writeManifest(in: folder, filename: "01. Track.flac")
        }

        func writeManifest(in folder: URL, filename: String) throws {
            let manifest = """
            {
              "version": 1,
              "files": {
                "\(filename)": {
                  "qobuzTrackID": "track",
                  "qobuzAlbumID": "album",
                  "formatID": 27,
                  "bitDepth": 24,
                  "samplingRate": 96,
                  "sha256": "\(String(repeating: "a", count: 64))",
                  "archiveKind": "album",
                  "isLibraryManaged": false
                }
              }
            }
            """
            try Data(manifest.utf8).write(
                to: folder.appendingPathComponent(QobuzProvenanceManifestIO.filename)
            )
        }
    }
}
