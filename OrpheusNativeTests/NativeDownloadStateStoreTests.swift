import XCTest
import NativeQobuzCore
@testable import OrpheusNative

final class NativeDownloadStateStoreTests: XCTestCase {
    func testOneOperationDrivesQueueAndActivityStatus() {
        let queueID = UUID()
        let activityID = UUID()
        var state = NativeDownloadStateStore()

        state.registerQueue(queueID)
        state.bindActivity(activityID, to: queueID)
        state.transition(queueID: queueID, to: .downloading)

        XCTAssertEqual(state.status(forQueueID: queueID), .downloading)
        XCTAssertEqual(state.status(forActivityID: activityID), .downloading)
        XCTAssertEqual(state.operations, [NativeDownloadOperation(
            queueID: queueID,
            activityID: activityID,
            status: .downloading
        )])
    }

    func testInterruptedOperationsNormalizeWithoutMutatingPayloadModels() {
        let activeQueueID = UUID()
        let activeActivityID = UUID()
        let completedQueueID = UUID()
        var state = NativeDownloadStateStore(operations: [
            NativeDownloadOperation(
                queueID: activeQueueID,
                activityID: activeActivityID,
                status: .validating
            ),
            NativeDownloadOperation(queueID: completedQueueID, status: .completed)
        ])

        let interrupted = state.normalizeAfterInterruption()

        XCTAssertEqual(interrupted, Set([activeActivityID]))
        XCTAssertEqual(state.status(forQueueID: activeQueueID), .paused)
        XCTAssertEqual(state.status(forActivityID: activeActivityID), .paused)
        XCTAssertEqual(state.status(forQueueID: completedQueueID), .completed)
    }

    func testSessionRejectsDuplicateAndMismatchedOperationBindings() throws {
        let queue = NativeQueueItem(request: .album(.init("album")), title: "Album")
        let activity = NativeDownloadActivity(id: UUID(), queueID: queue.id, title: queue.title)
        let valid = NativeDownloadOperation(
            queueID: queue.id,
            activityID: activity.id,
            status: .paused
        )

        var duplicate = NativeSessionSnapshot(
            queue: [queue],
            activities: [activity],
            operations: [valid, valid],
            selectedQueueID: queue.id,
            linkInbox: []
        )
        XCTAssertThrowsError(try duplicate.validate())

        duplicate.operations = [NativeDownloadOperation(
            queueID: queue.id,
            activityID: UUID(),
            status: .paused
        )]
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testIncompatibleSessionIsQuarantinedAndStartsFresh() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeSessionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root,
            defaultDownloadRoot: root.appendingPathComponent("Music", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":2,"queue":[],"activities":[]}"#.utf8)
            .write(to: paths.sessionURL)

        let restored = try NativeSessionStore(paths: paths).load()

        XCTAssertNil(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionURL.path))
        let rejected = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("download-session.rejected-") && $0.hasSuffix(".json") }
        XCTAssertEqual(rejected.count, 1)
    }
}
