import Foundation
import XCTest
@testable import NativeQobuzCore

final class ArchiveSnapshotValidationTests: XCTestCase {
    func testDecodeRejectsDuplicatePhysicalPathsWithoutProjectionCrash() throws {
        let first = track(path: "Artist/Album/01.flac", trackID: "one")
        let duplicate = track(path: first.relativePath, trackID: "two")
        let malformed = QobuzArchiveSnapshot(rootPath: "/Music", tracks: [first, duplicate])

        XCTAssertThrowsError(try roundTripDecode(malformed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate physical track paths"))
        }
        XCTAssertEqual(malformed.library.entries.flatMap(\.tracks).count, 1)
    }

    func testDecodeRejectsDuplicateCollectionIDs() throws {
        let physical = track(path: "Artist/Album/01.flac", trackID: "one")
        let first = collection(id: "album|one", qobuzID: "one", path: physical.relativePath)
        let duplicate = collection(id: first.id, qobuzID: "one", path: physical.relativePath)

        XCTAssertThrowsError(try roundTripDecode(snapshot(physical, collections: [first, duplicate]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate collection IDs"))
        }
    }

    func testDecodeRejectsDuplicateLinkRecordsWithinCollection() throws {
        let physical = track(path: "Artist/Album/01.flac", trackID: "one")
        let malformed = collection(
            id: "album|one",
            qobuzID: "one",
            path: physical.relativePath,
            trackPaths: [physical.relativePath, physical.relativePath]
        )

        XCTAssertThrowsError(try roundTripDecode(snapshot(physical, collections: [malformed]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate collection link records"))
        }
    }

    func testDecodeRejectsLinkToMissingPhysicalTrack() throws {
        let physical = track(path: "Artist/Album/01.flac", trackID: "one")
        let malformed = collection(
            id: "album|one",
            qobuzID: "one",
            path: physical.relativePath,
            trackPaths: ["Artist/Album/02.flac"]
        )

        XCTAssertThrowsError(try roundTripDecode(snapshot(physical, collections: [malformed]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing physical track"))
        }
    }

    private func roundTripDecode(_ snapshot: QobuzArchiveSnapshot) throws -> QobuzArchiveSnapshot {
        try JSONDecoder().decode(QobuzArchiveSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    private func snapshot(
        _ track: QobuzArchiveTrack,
        collections: [QobuzLibraryCollectionRecord]
    ) -> QobuzArchiveSnapshot {
        QobuzArchiveSnapshot(rootPath: "/Music", tracks: [track], collections: collections)
    }

    private func track(path: String, trackID: String) -> QobuzArchiveTrack {
        QobuzArchiveTrack(
            relativePath: path,
            qobuzTrackID: trackID,
            qobuzAlbumID: "one",
            formatID: 27,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: String(repeating: "a", count: 64),
            integrity: .verified,
            archiveKind: .album
        )
    }

    private func collection(
        id: String,
        qobuzID: String,
        path: String,
        trackPaths: [String]? = nil
    ) -> QobuzLibraryCollectionRecord {
        QobuzLibraryCollectionRecord(
            id: id,
            kind: .album,
            qobuzID: qobuzID,
            title: "Album",
            subtitle: "Artist",
            relativePath: QobuzPathSafety.directoryPath(of: path),
            trackPaths: trackPaths ?? [path]
        )
    }
}
