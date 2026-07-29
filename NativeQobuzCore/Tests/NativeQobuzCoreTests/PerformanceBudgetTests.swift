import XCTest
@testable import NativeQobuzCore

final class PerformanceBudgetTests: XCTestCase {
    func testArchiveIndexBuildAndLookupBudgets() {
        let trackCount = 25_000
        let tracks = (0..<trackCount).map { index in
            QobuzArchiveTrack(
                relativePath: "Artist \(index / 500)/Album \(index / 50)/\(index).flac",
                qobuzTrackID: "track-\(index)",
                qobuzAlbumID: "album-\(index / 50)",
                formatID: 27,
                expectedSHA256: String(repeating: "a", count: 64),
                actualSHA256: String(repeating: "a", count: 64),
                integrity: .verified,
                archiveKind: .album
            )
        }
        let clock = ContinuousClock()
        var index: QobuzArchiveLookupIndex?
        let buildDuration = clock.measure {
            index = QobuzArchiveLookupIndex(
                tracks: tracks,
                issues: [],
                collections: []
            )
        }

        XCTAssertLessThan(
            buildDuration,
            .seconds(3),
            "25k-track archive index build exceeded its 3 s CI budget: \(buildDuration)"
        )

        var matched = 0
        let lookupDuration = clock.measure {
            for lookup in 0..<10_000 {
                let track = lookup % trackCount
                matched += index?.coverage(
                    trackIDs: [QobuzID("track-\(track)")],
                    albumID: QobuzID("album-\(track / 50)")
                ).matchedCount ?? 0
            }
        }
        XCTAssertEqual(matched, 10_000)
        XCTAssertLessThan(
            lookupDuration,
            .seconds(1),
            "10k indexed Library lookups exceeded their 1 s CI budget: \(lookupDuration)"
        )
    }
}
