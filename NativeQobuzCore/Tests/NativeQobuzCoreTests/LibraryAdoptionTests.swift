import Foundation
import XCTest
@testable import NativeQobuzCore

final class LibraryAdoptionTests: XCTestCase {
    func testAdoptionRepairsMalformedCollectionIdentity() async throws {
        try await assertSemanticRepair {
            Self.albumRecord(id: "album|wrong")
        }
    }

    func testAdoptionRepairsMalformedCollectionLink() async throws {
        try await assertSemanticRepair {
            Self.albumRecord(trackPaths: ["Another/Folder/ghost.flac"])
        }
    }

    func testAdoptionRepairsArtworkOutsideCollectionFolder() async throws {
        try await assertSemanticRepair {
            Self.albumRecord(artworkRelativePath: "Another/Folder/cover.jpg")
        }
    }

    func testAdoptionRepairsUnclassifiedLogicalCollection() async throws {
        try await assertSemanticRepair {
            QobuzLibraryCollectionRecord(
                id: "unclassified|album",
                kind: .unclassified,
                qobuzID: "album",
                title: "CORRUPTED",
                subtitle: "Invalid",
                relativePath: Self.trackPath,
                trackPaths: [Self.trackPath]
            )
        }
    }

    func testVerificationFailureRestoresUnreadableManifestExactly() async throws {
        let fixture = try AdoptionFixture()
        defer { fixture.cleanup() }
        let original = Data("{malformed but important".utf8)
        let manifestPath = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        try fixture.files.writeAtomically(original, to: manifestPath)
        let adopter = QobuzLibraryAdopter(
            scanner: AdoptionProjectionScanner(failVerification: true)
        )

        do {
            _ = try await adopter.prepare(root: fixture.root)
            XCTFail("Verification failure should abort adoption")
        } catch is AdoptionVerificationFailure {
            // Expected: the transaction must restore the exact original bytes.
        }

        XCTAssertEqual(try fixture.files.read(manifestPath), original)
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testAdoptionFailsClosedWhenPlaylistCannotBeDecoded() async throws {
        let fixture = try AdoptionFixture()
        defer { fixture.cleanup() }
        let playlist = try LibraryRelativePath("Playlists/Mix [mix]/Mix.m3u")
        try fixture.files.writeAtomically(Data([0xFF, 0xFE, 0xFD]), to: playlist)
        let adopter = QobuzLibraryAdopter(scanner: AdoptionProjectionScanner())

        do {
            _ = try await adopter.inspect(root: fixture.root)
            XCTFail("Unreadable playlist bytes must not be silently omitted from a rebuilt manifest")
        } catch let error as LibraryFileSystemError {
            XCTAssertEqual(error, .notRegularFile(playlist.rawValue))
        }
    }

    func testAdoptionFailsClosedWhenPlaylistDescriptionCannotBeDecoded() async throws {
        let fixture = try AdoptionFixture()
        defer { fixture.cleanup() }
        let folder = try LibraryRelativePath("Playlists/Mix [mix]")
        try fixture.files.writeAtomically(
            Data("#EXTM3U\n../../Artist/Album/01. Song.flac\n".utf8),
            to: try folder.appending("Mix.m3u")
        )
        let description = try folder.appending(QobuzManagedLibraryAssetPolicy.descriptionFilename)
        try fixture.files.writeAtomically(Data([0xFF, 0xFE, 0xFD]), to: description)
        let adopter = QobuzLibraryAdopter(scanner: AdoptionProjectionScanner())

        do {
            _ = try await adopter.inspect(root: fixture.root)
            XCTFail("Unreadable description bytes must not silently erase playlist presentation")
        } catch let error as LibraryFileSystemError {
            XCTAssertEqual(error, .notRegularFile(description.rawValue))
        }
    }

    private func assertSemanticRepair(
        malformedRecord: () -> QobuzLibraryCollectionRecord
    ) async throws {
        let fixture = try AdoptionFixture()
        defer { fixture.cleanup() }
        try QobuzLibraryManifestIO.save(
            QobuzLibraryManifest(collections: [malformedRecord()]),
            in: fixture.files
        )
        let adopter = QobuzLibraryAdopter(scanner: AdoptionProjectionScanner())

        let plan = try await adopter.inspect(root: fixture.root)

        XCTAssertEqual(plan.manifestAction, .repair)
        XCTAssertEqual(plan.existingCollectionCount, 1)
        XCTAssertEqual(plan.proposedManifest.collections.map(\.id), ["album|album"])
        XCTAssertEqual(plan.proposedManifest.collections.first?.trackPaths, [Self.trackPath])
        XCTAssertNotEqual(plan.proposedManifest.collections.first?.title, "CORRUPTED")

        let result = try await adopter.adopt(root: fixture.root)
        XCTAssertEqual(result.snapshot.collections, plan.proposedManifest.collections)
        try result.snapshot.validate()
    }

    fileprivate static let trackPath = "Artist/Album/01. Song.flac"

    private static func albumRecord(
        id: String = "album|album",
        trackPaths: [String] = [trackPath],
        artworkRelativePath: String? = nil
    ) -> QobuzLibraryCollectionRecord {
        QobuzLibraryCollectionRecord(
            id: id,
            kind: .album,
            qobuzID: "album",
            title: "CORRUPTED",
            subtitle: "Invalid",
            relativePath: "Artist/Album",
            trackPaths: trackPaths,
            artworkRelativePath: artworkRelativePath
        )
    }
}

private struct AdoptionFixture {
    let root: URL
    let files: LibraryFileSystem

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryAdoptionTests-\(UUID().uuidString)", isDirectory: true)
        files = try LibraryFileSystem(rootURL: root)
        try files.writeAtomically(
            Data("audio".utf8),
            to: LibraryRelativePath(LibraryAdoptionTests.trackPath)
        )
    }

    func transactionDirectories() throws -> [LibraryDirectoryEntry] {
        try files.entries(in: .root).filter {
            $0.path.lastComponent?.hasPrefix(LibraryFileTransactionJournal.directoryPrefix) == true
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class AdoptionProjectionScanner: QobuzArchiveScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let failVerification: Bool
    private var scanCount = 0

    init(failVerification: Bool = false) {
        self.failVerification = failVerification
    }

    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        let currentScan = lock.withLock {
            scanCount += 1
            return scanCount
        }
        if failVerification, currentScan > 1 { throw AdoptionVerificationFailure.injected }
        let files = try LibraryFileSystem(rootURL: root, createIfMissing: false)
        let collections = (try? QobuzLibraryManifestIO.load(in: files).collections) ?? []
        let digest = MusicFileIntegrity.sha256(of: Data("audio".utf8))
        return QobuzArchiveSnapshot(
            rootPath: root.standardizedFileURL.path,
            tracks: [
                QobuzArchiveTrack(
                    relativePath: LibraryAdoptionTests.trackPath,
                    qobuzTrackID: "track",
                    qobuzAlbumID: "album",
                    formatID: 6,
                    expectedSHA256: digest,
                    actualSHA256: digest,
                    byteCount: 5,
                    integrity: .verified,
                    archiveKind: .album,
                    isLibraryManaged: true
                )
            ],
            collections: collections
        )
    }
}

private enum AdoptionVerificationFailure: Error {
    case injected
}
