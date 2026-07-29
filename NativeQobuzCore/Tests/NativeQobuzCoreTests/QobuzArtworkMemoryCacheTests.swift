import Foundation
import XCTest
@testable import NativeQobuzCore

final class QobuzArtworkMemoryCacheTests: XCTestCase {
    func testCacheSharesPositiveAndNegativeResultsUnderOneBoundedOwner() {
        let cache = QobuzArtworkMemoryCache(maximumBytes: 8, maximumEntries: 2)
        let firstID = QobuzID("first")
        let missingID = QobuzID("missing")
        let thirdID = QobuzID("third")
        let first = artwork(bytes: 4)
        let third = artwork(bytes: 6)

        cache.store(first, for: firstID)
        cache.store(nil, for: missingID)
        XCTAssertArtwork(cache.lookup(firstID), equals: first)
        guard case .missing = cache.lookup(missingID) else {
            return XCTFail("Expected a cached negative artwork result")
        }

        cache.store(third, for: thirdID)

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.retainedBytes, 6)
        guard case .notCached = cache.lookup(firstID) else {
            return XCTFail("Expected the least-recent entries to be evicted")
        }
        guard case .missing = cache.lookup(missingID) else {
            return XCTFail("Expected the negative cache entry to remain bounded with artwork")
        }
        XCTAssertArtwork(cache.lookup(thirdID), equals: third)
    }

    private func artwork(bytes: Int) -> EmbeddedArtwork {
        EmbeddedArtwork(
            data: Data(repeating: 0x7f, count: bytes),
            mimeType: "image/jpeg",
            width: 1,
            height: 1,
            depth: 24
        )
    }

    private func XCTAssertArtwork(
        _ lookup: QobuzArtworkCacheLookup,
        equals expected: EmbeddedArtwork,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .artwork(let actual) = lookup else {
            return XCTFail("Expected cached artwork", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
