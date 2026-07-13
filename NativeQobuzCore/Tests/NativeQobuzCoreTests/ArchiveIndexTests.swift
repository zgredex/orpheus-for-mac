import Foundation
import XCTest
@testable import NativeQobuzCore

final class ArchiveIndexTests: XCTestCase {
    func testScannerIndexesExactIDsAndIntegrityWithoutFilenameInference() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let albumFolder = root.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        let verifiedURL = albumFolder.appendingPathComponent("01. Completely Arbitrary Name.flac")
        let changedURL = albumFolder.appendingPathComponent("02. Changed.flac")
        try Data("verified".utf8).write(to: verifiedURL)
        try Data("changed".utf8).write(to: changedURL)
        let verifiedHash = try MusicFileIntegrity.sha256(of: verifiedURL)
        let originalChangedHash = try MusicFileIntegrity.sha256(of: changedURL)
        let manifest = TestManifest(files: [
            verifiedURL.lastPathComponent: provenance(
                trackID: "track-exact",
                albumID: "album-exact",
                hash: verifiedHash
            ),
            changedURL.lastPathComponent: provenance(
                trackID: "track-changed",
                albumID: "album-exact",
                hash: String(repeating: "0", count: 64)
            ),
            "03. Missing.flac": provenance(
                trackID: "track-missing",
                albumID: "album-exact",
                hash: String(repeating: "1", count: 64)
            )
        ])
        try JSONEncoder().encode(manifest).write(
            to: albumFolder.appendingPathComponent(".orpheus-provenance.json")
        )
        try Data("""
        \(verifiedHash)  \(verifiedURL.lastPathComponent)
        \(originalChangedHash)  \(changedURL.lastPathComponent)
        """.utf8).write(to: albumFolder.appendingPathComponent("checksums.sha256"))

        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertEqual(snapshot.albumCount, 1)
        XCTAssertEqual(snapshot.tracks.count, 3)
        XCTAssertEqual(snapshot.verifiedCount, 1)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "track-exact" }?.integrity, .verified)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "track-changed" }?.integrity, .metadataConflict)
        XCTAssertEqual(snapshot.tracks.first { $0.qobuzTrackID == "track-missing" }?.integrity, .missing)
        XCTAssertEqual(
            snapshot.tracks.first { $0.qobuzTrackID == "track-exact" }?.relativePath,
            "Artist/Album/01. Completely Arbitrary Name.flac"
        )
    }

    func testScannerReportsMalformedManifestsAndUnsafeFilenames() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: first.appendingPathComponent(".orpheus-provenance.json"))
        let unsafe = TestManifest(files: [
            "../outside.flac": provenance(
                trackID: "outside",
                albumID: "outside",
                hash: String(repeating: "0", count: 64)
            )
        ])
        try JSONEncoder().encode(unsafe).write(to: second.appendingPathComponent(".orpheus-provenance.json"))

        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertTrue(snapshot.issues.contains { $0.message.contains("unsafe") })
    }

    func testMissingRootReturnsAnEmptyDiagnosticSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshot = try await QobuzArchiveScanner().scan(root: root)

        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertEqual(snapshot.issues.first?.message, "Download folder does not exist yet.")
    }

    func testCoverageUsesExactTrackAndAlbumIDs() {
        let snapshot = QobuzArchiveSnapshot(rootPath: "/Music", tracks: [
            archiveTrack(trackID: "one", albumID: "album-a", integrity: .verified),
            archiveTrack(trackID: "two", albumID: "album-a", integrity: .checksumMismatch),
            archiveTrack(trackID: "one", albumID: "album-b", integrity: .verified)
        ])

        let album = snapshot.coverage(
            trackIDs: [QobuzID("one"), QobuzID("two"), QobuzID("missing")],
            albumID: QobuzID("album-a")
        )
        XCTAssertEqual(album.matchedCount, 2)
        XCTAssertEqual(album.verifiedCount, 1)
        XCTAssertEqual(album.problemCount, 1)
        XCTAssertEqual(album.expectedCount, 3)
        XCTAssertFalse(album.isComplete)

        let wrongAlbum = snapshot.coverage(
            trackID: QobuzID("one"),
            albumID: QobuzID("not-this-album")
        )
        XCTAssertEqual(wrongAlbum.matchedCount, 0)
    }

    func testCoverageOnlyClaimsCompleteWhenEveryExpectedTrackIsClean() {
        let clean = archiveTrack(trackID: "one", albumID: "album", integrity: .verified)
        let duplicateProblem = archiveTrack(
            relativePath: "duplicate.flac",
            trackID: "one",
            albumID: "album",
            integrity: .checksumMismatch
        )
        let snapshot = QobuzArchiveSnapshot(rootPath: "/Music", tracks: [clean, duplicateProblem])

        let coverage = snapshot.coverage(trackID: QobuzID("one"), albumID: QobuzID("album"))
        XCTAssertEqual(coverage.verifiedCount, 1)
        XCTAssertEqual(coverage.problemCount, 1)
        XCTAssertFalse(coverage.isComplete)
    }

    func testProblemCountDoesNotDoubleCountATrackDiagnostic() {
        let unreadable = archiveTrack(
            relativePath: "Album/unreadable.flac",
            trackID: "one",
            albumID: "album",
            integrity: .unreadable
        )
        let snapshot = QobuzArchiveSnapshot(
            rootPath: "/Music",
            tracks: [unreadable],
            issues: [
                QobuzArchiveIssue(relativePath: unreadable.relativePath, message: "Permission denied"),
                QobuzArchiveIssue(relativePath: "Broken/.orpheus-provenance.json", message: "Malformed")
            ]
        )

        XCTAssertEqual(snapshot.problemCount, 2)
    }

    private struct TestManifest: Encodable {
        let version = 1
        let files: [String: QobuzFileProvenance]
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusArchiveTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func provenance(trackID: String, albumID: String, hash: String) -> QobuzFileProvenance {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        let album = QobuzAlbum(id: QobuzID(albumID), title: "Album", artist: artist)
        let track = QobuzTrack(id: QobuzID(trackID), title: "Track", performer: artist)
        let item = QobuzResolvedTrack(track: track, album: album, collection: .album(id: album.id, title: album.title), position: 1, total: 1)
        return QobuzFileProvenance(
            item: item,
            fileInfo: QobuzFileInfo(url: URL(string: "https://media.example/file.flac")!, formatID: 27, bitDepth: 24, samplingRate: 96),
            sha256: hash
        )
    }

    private func archiveTrack(
        relativePath: String = "track.flac",
        trackID: String,
        albumID: String,
        integrity: QobuzArchiveIntegrity
    ) -> QobuzArchiveTrack {
        QobuzArchiveTrack(
            relativePath: relativePath,
            qobuzTrackID: trackID,
            qobuzAlbumID: albumID,
            formatID: 27,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: integrity == .verified ? String(repeating: "a", count: 64) : nil,
            integrity: integrity
        )
    }
}
