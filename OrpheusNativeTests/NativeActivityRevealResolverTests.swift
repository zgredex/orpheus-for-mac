import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

final class NativeActivityRevealResolverTests: XCTestCase {
    func testCompletedActivityRevealUsesRelocatedLibrarySnapshotPath() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativeActivityRevealResolverTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let oldRoot = sandbox.appendingPathComponent("Old Library", isDirectory: true)
        let newRoot = sandbox.appendingPathComponent("New Library", isDirectory: true)
        let relativePath = "Artist/Album/01. Track.flac"
        let oldOutput = oldRoot.appendingPathComponent(relativePath)
        let relocatedOutput = newRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: relocatedOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("relocated audio".utf8).write(to: relocatedOutput)

        var operation = NativeDownloadOperation(
            queueID: UUID(),
            activityID: UUID(),
            status: .completed,
            title: "Track"
        )
        operation.downloadRootPath = oldRoot.standardizedFileURL.path
        operation.recordOutput(oldOutput)
        operation.recordCheckpoint(QobuzDownloadCheckpoint(phase: .complete))
        let snapshot = QobuzArchiveSnapshot(
            rootPath: newRoot.standardizedFileURL.path,
            tracks: [
                QobuzArchiveTrack(
                    relativePath: relativePath,
                    qobuzTrackID: "track",
                    qobuzAlbumID: "album",
                    formatID: QobuzAudioFormat.hiRes.formatID,
                    expectedSHA256: "checksum",
                    integrity: .verified
                )
            ]
        )

        let target = NativeActivityRevealResolver().target(
            for: NativeDownloadActivity(operation: operation),
            currentLibrarySnapshot: snapshot
        )

        XCTAssertEqual(target, relocatedOutput.standardizedFileURL)
        XCTAssertNotEqual(target, oldOutput.standardizedFileURL)
    }

    func testRecoveryRevealRefusesLibraryRootReplacedBySymlink() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativeActivityRevealSymlinkTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let outside = sandbox.appendingPathComponent("Outside", isDirectory: true)
        let root = sandbox.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        var operation = NativeDownloadOperation(
            queueID: UUID(),
            activityID: UUID(),
            status: .failed("Interrupted"),
            title: "Track"
        )
        operation.downloadRootPath = root.path

        let target = NativeActivityRevealResolver().target(
            for: NativeDownloadActivity(operation: operation),
            currentLibrarySnapshot: nil
        )

        XCTAssertNil(target)
    }
}
