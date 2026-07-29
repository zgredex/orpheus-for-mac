import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

final class NativeLogQueryIndexTests: XCTestCase {
    func testIndexCachesSearchMaterialAndMaintainsLevelAndCategoryCounts() {
        let info = entry(level: .info, category: "browse", message: "Loaded page")
        let error = entry(
            level: .error,
            category: "download",
            message: "Transfer failed",
            metadata: ["trackID": "qobuz-123"],
            errorDescription: "The server disconnected"
        )
        var index = NativeLogQueryIndex(limit: 10)

        index.replace(with: [info, error])

        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.categories, ["browse", "download"])
        XCTAssertEqual(index.count(for: .info), 1)
        XCTAssertEqual(index.count(for: .error), 1)
        XCTAssertEqual(
            index.filtered(minimumLevel: .trace, category: "All", query: "QOBUZ-123"),
            [error]
        )
        XCTAssertEqual(
            index.filtered(minimumLevel: .warning, category: "download", query: "disconnected"),
            [error]
        )
    }

    func testIndexDeduplicatesAndEvictsWithoutLosingAuthoritativeLookups() {
        let first = entry(level: .debug, category: "one", message: "First")
        let second = entry(level: .warning, category: "two", message: "Second")
        let third = entry(level: .critical, category: "three", message: "Third")
        var index = NativeLogQueryIndex(limit: 2)

        index.append(first)
        index.append(first)
        index.append(second)
        index.append(third)

        XCTAssertEqual(index.count, 2)
        XCTAssertNil(index.entry(id: first.id))
        XCTAssertEqual(index.entry(id: second.id), second)
        XCTAssertEqual(index.entry(id: third.id), third)
        XCTAssertEqual(index.categories, ["three", "two"])
        XCTAssertEqual(
            index.filtered(minimumLevel: .trace, category: "All", query: "").map(\.id),
            [second.id, third.id]
        )
    }

    private func entry(
        level: QobuzLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:],
        errorDescription: String? = nil
    ) -> QobuzLogEntry {
        QobuzLogEntry(
            sessionID: UUID(),
            level: level,
            category: category,
            message: message,
            metadata: metadata,
            errorDescription: errorDescription,
            sourceFile: "Tests.swift",
            sourceFunction: #function,
            sourceLine: #line,
            thread: "test"
        )
    }
}
