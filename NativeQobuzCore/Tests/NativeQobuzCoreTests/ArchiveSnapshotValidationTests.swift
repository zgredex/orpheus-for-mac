import Foundation
import XCTest
@testable import NativeQobuzCore

final class ArchiveSnapshotValidationTests: XCTestCase {
    func testDecodeRejectsSnapshotMissingCurrentProjectionFields() throws {
        let encoded = try JSONEncoder().encode(
            QobuzArchiveSnapshot(rootPath: "/Music", tracks: [], issues: [], collections: [])
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for requiredKey in ["issues", "collections"] {
            var incomplete = object
            incomplete.removeValue(forKey: requiredKey)
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    QobuzArchiveSnapshot.self,
                    from: JSONSerialization.data(withJSONObject: incomplete)
                ),
                "Expected missing \(requiredKey) to reject the persisted archive snapshot."
            )
        }
    }

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

    func testPlaylistMayReferenceTheSamePhysicalTrackAtMultiplePositions() throws {
        let physical = track(path: "Artist/Album/01.flac", trackID: "one")
        let playlist = QobuzLibraryCollectionRecord(
            id: "playlist|mix",
            kind: .playlist,
            qobuzID: "mix",
            title: "Mix",
            subtitle: "Owner · 2 tracks",
            relativePath: "Playlists/Mix [mix]",
            trackPaths: [physical.relativePath, physical.relativePath],
            sourceTrackCount: 2
        )

        let decoded = try roundTripDecode(snapshot(physical, collections: [playlist]))

        XCTAssertEqual(decoded.collections.first?.trackPaths.count, 2)
        XCTAssertEqual(decoded.library.entries.first?.tracks.count, 2)
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

    func testDecodeRejectsOverflowingAndNegativeTrackSizesWithoutProjectionTrap() throws {
        let first = track(
            path: "Artist/Album/01.flac",
            trackID: "one",
            byteCount: Int64.max
        )
        let second = track(
            path: "Artist/Album/02.flac",
            trackID: "two",
            byteCount: Int64.max
        )
        let overflowing = QobuzArchiveSnapshot(rootPath: "/Music", tracks: [first, second])

        XCTAssertThrowsError(try roundTripDecode(overflowing)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overflowing file sizes"))
        }
        XCTAssertNil(overflowing.library.entries.first?.byteCount)

        let negative = QobuzArchiveSnapshot(
            rootPath: "/Music",
            tracks: [track(path: "Artist/Album/03.flac", trackID: "three", byteCount: -1)]
        )
        XCTAssertThrowsError(try roundTripDecode(negative)) { error in
            XCTAssertTrue(error.localizedDescription.contains("negative file size"))
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

    private func track(
        path: String,
        trackID: String,
        byteCount: Int64? = nil
    ) -> QobuzArchiveTrack {
        QobuzArchiveTrack(
            relativePath: path,
            qobuzTrackID: trackID,
            qobuzAlbumID: "one",
            formatID: 27,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: String(repeating: "a", count: 64),
            byteCount: byteCount,
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
