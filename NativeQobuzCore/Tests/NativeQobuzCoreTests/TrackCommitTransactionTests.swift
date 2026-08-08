import Foundation
import XCTest
@testable import NativeQobuzCore

final class TrackCommitTransactionTests: XCTestCase {
    func testFailureAfterProvenanceWriteRestoresAudioProvenanceAndProcessingFile() async throws {
        let fixture = try TrackCommitFixture()
        defer { fixture.cleanup() }
        let oldData = Data("old tagged audio".utf8)
        let newData = Data("new tagged audio".utf8)
        try fixture.fileSystem.writeAtomically(oldData, to: fixture.destination)
        let oldProvenance = try fixture.provenance(sha256: MusicFileIntegrity.sha256(of: oldData))
        try fixture.store.record(
            oldProvenance,
            for: fixture.destinationURL,
            fileSystem: fixture.fileSystem
        )
        try fixture.fileSystem.writeAtomically(newData, to: fixture.processing)
        let newProvenance = try fixture.provenance(sha256: MusicFileIntegrity.sha256(of: newData))
        let transaction = QobuzTrackCommitTransaction { checkpoint in
            if case .appliedMutation(index: 1) = checkpoint {
                throw TrackCommitFailure.injected
            }
        }

        do {
            try await transaction.commit(
                provenance: newProvenance,
                expectedSHA256: newProvenance.sha256,
                stagingURL: fixture.processingURL,
                destinationURL: fixture.destinationURL,
                fileSystem: fixture.fileSystem
            )
            XCTFail("The injected failure should abort the commit")
        } catch TrackCommitFailure.injected {}

        XCTAssertEqual(try fixture.fileSystem.read(fixture.destination), oldData)
        XCTAssertEqual(try fixture.fileSystem.read(fixture.processing), newData)
        XCTAssertEqual(
            try fixture.store.provenance(for: fixture.destinationURL, fileSystem: fixture.fileSystem),
            oldProvenance
        )
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testCommitRefusesSymlinkDestinationWithoutTouchingTargetOrProcessingFile() async throws {
        let fixture = try TrackCommitFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "TrackCommitOutside-\(UUID().uuidString).flac"
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideData = Data("outside sentinel".utf8)
        let stagedData = Data("staged audio".utf8)
        try outsideData.write(to: outside)
        try fixture.fileSystem.writeAtomically(stagedData, to: fixture.processing)
        try FileManager.default.createSymbolicLink(
            at: fixture.destinationURL,
            withDestinationURL: outside
        )
        let provenance = try fixture.provenance(sha256: MusicFileIntegrity.sha256(of: stagedData))

        do {
            try await QobuzTrackCommitTransaction().commit(
                provenance: provenance,
                expectedSHA256: provenance.sha256,
                stagingURL: fixture.processingURL,
                destinationURL: fixture.destinationURL,
                fileSystem: fixture.fileSystem
            )
            XCTFail("A symbolic-link destination should be rejected")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
        XCTAssertEqual(try fixture.fileSystem.read(fixture.processing), stagedData)
        XCTAssertNil(try fixture.store.provenance(
            for: fixture.destinationURL,
            fileSystem: fixture.fileSystem
        ))
    }

    func testCommitRejectsProvenanceChecksumDifferentFromStagedChecksum() async throws {
        let fixture = try TrackCommitFixture()
        defer { fixture.cleanup() }
        let stagedData = Data("staged audio".utf8)
        try fixture.fileSystem.writeAtomically(stagedData, to: fixture.processing)
        let stagedChecksum = MusicFileIntegrity.sha256(of: stagedData)
        let provenance = try fixture.provenance(sha256: String(repeating: "0", count: 64))

        do {
            try await QobuzTrackCommitTransaction().commit(
                provenance: provenance,
                expectedSHA256: stagedChecksum,
                stagingURL: fixture.processingURL,
                destinationURL: fixture.destinationURL,
                fileSystem: fixture.fileSystem
            )
            XCTFail("Mismatched provenance should be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provenance"))
        }

        XCTAssertEqual(try fixture.fileSystem.read(fixture.processing), stagedData)
        XCTAssertNil(try fixture.fileSystem.metadata(at: fixture.destination))
    }
}

private enum TrackCommitFailure: Error { case injected }

private struct TrackCommitFixture {
    let root: URL
    let fileSystem: LibraryFileSystem
    let destination: LibraryRelativePath
    let processing: LibraryRelativePath
    let store = QobuzProvenanceStore()
    let item: QobuzResolvedTrack

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TrackCommitTransactionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        fileSystem = try LibraryFileSystem(rootURL: root)
        destination = try LibraryRelativePath("Artist/Album/01. Track.flac")
        processing = try LibraryRelativePath("Artist/Album/01. Track.processing")
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        let summary = QobuzAlbumSummary(
            id: QobuzID("album"),
            title: "Album",
            artist: artist
        )
        let track = QobuzTrack(
            id: QobuzID("track"),
            title: "Track",
            performer: artist,
            album: summary,
            trackNumber: 1,
            mediaNumber: 1
        )
        let album = QobuzAlbum(
            id: summary.id,
            title: summary.title,
            artist: artist,
            tracks: [track],
            tracksCount: 1,
            mediaCount: 1
        )
        item = QobuzResolvedTrack(
            track: track,
            album: album,
            collection: .album(id: album.id, title: album.title),
            position: 1,
            total: 1
        )
    }

    var destinationURL: URL { fileSystem.displayURL(for: destination) }
    var processingURL: URL { fileSystem.displayURL(for: processing) }

    func provenance(sha256: String) throws -> QobuzFileProvenance {
        let info = QobuzFileInfo(
            url: URL(string: "https://media.example/track.flac")!,
            format: .lossless,
            bitDepth: 16,
            samplingRate: 44.1
        )
        return QobuzFileProvenance(
            item: item,
            delivery: try validatedTestDelivery(for: info),
            sha256: sha256
        )
    }

    func transactionDirectories() throws -> [LibraryDirectoryEntry] {
        try fileSystem.entries(in: .root).filter {
            $0.path.lastComponent?.hasPrefix(LibraryFileTransactionJournal.directoryPrefix) == true
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
