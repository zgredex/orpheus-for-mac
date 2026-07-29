import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativePerformanceBudgetTests: XCTestCase {
    func testIndexedDownloadTelemetryBudget() {
        let operationCount = 10_000
        let operations = (0..<operationCount).map { index in
            NativeDownloadOperation(
                queueID: deterministicUUID(index),
                activityID: deterministicUUID(index + operationCount),
                status: .downloading,
                title: "Track \(index)"
            )
        }
        let clock = ContinuousClock()
        var state: NativeDownloadStateStore?
        let buildDuration = clock.measure {
            state = NativeDownloadStateStore(operations: operations)
        }
        XCTAssertLessThan(
            buildDuration,
            .seconds(2),
            "10k-operation download index build exceeded its 2 s CI budget: \(buildDuration)"
        )

        var newlyRegistered = NativeDownloadStateStore()
        let registrationDuration = clock.measure {
            newlyRegistered.registerQueues(operations.map(\.queueID))
        }
        XCTAssertEqual(newlyRegistered.operations.count, operationCount)
        XCTAssertLessThan(
            registrationDuration,
            .seconds(2),
            "10k queue registrations exceeded their 2 s CI budget: \(registrationDuration)"
        )

        let mutationDuration = clock.measure {
            for index in 0..<20_000 {
                state?.mutateOperation(queueID: deterministicUUID(index % operationCount)) {
                    $0.progress = Double(index % 100) / 100
                    $0.bytesWritten = Int64(index)
                }
            }
        }
        XCTAssertEqual(state?.operations.count, operationCount)
        XCTAssertLessThan(
            mutationDuration,
            .seconds(2),
            "20k indexed telemetry mutations exceeded their 2 s CI budget: \(mutationDuration)"
        )
    }

    func testDiagnosticsIndexAndSearchBudget() {
        let entries = (0..<5_000).map { index in
            QobuzLogEntry(
                sessionID: deterministicUUID(1),
                level: index.isMultiple(of: 25) ? .error : .debug,
                category: index.isMultiple(of: 2) ? "download" : "browse",
                message: "Diagnostic event \(index)",
                metadata: ["trackID": "track-\(index)", "phase": "validation"],
                sourceFile: "PerformanceBudgetTests.swift",
                sourceFunction: #function,
                sourceLine: #line,
                thread: "test"
            )
        }
        let clock = ContinuousClock()
        var index = NativeLogQueryIndex(limit: 5_000)
        let buildDuration = clock.measure {
            index.replace(with: entries)
        }
        let searchDuration = clock.measure {
            _ = index.filtered(
                minimumLevel: .warning,
                category: "download",
                query: "track-2500"
            )
        }

        XCTAssertLessThan(
            buildDuration,
            .seconds(1),
            "5k-event diagnostics indexing exceeded its 1 s CI budget: \(buildDuration)"
        )
        XCTAssertLessThan(
            searchDuration,
            .milliseconds(100),
            "Indexed diagnostics search exceeded its 100 ms CI budget: \(searchDuration)"
        )
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(value))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
