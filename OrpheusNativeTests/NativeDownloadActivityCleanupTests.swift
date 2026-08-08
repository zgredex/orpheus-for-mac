import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeDownloadActivityCleanupTests: XCTestCase {
    func testRemoveActivityDeletesExactPartialAndProcessingBeforeClearingOwnership() throws {
        let fixture = try CleanupFixture(queueExists: true)
        try fixture.createRegularArtifact(at: fixture.partial, data: Data())
        try fixture.createRegularArtifact(at: fixture.processing, data: Data("staged".utf8))
        let unrelated = fixture.partial.appendingPathExtension("unrelated")
        try fixture.createRegularArtifact(at: unrelated, data: Data("keep".utf8))
        fixture.restore()

        fixture.controller.removeActivity(try XCTUnwrap(fixture.controller.activities.first))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.processing.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        let retainedQueue = try XCTUnwrap(fixture.controller.operations.first)
        XCTAssertNil(retainedQueue.activityID)
        XCTAssertEqual(retainedQueue.status, .ready)
        XCTAssertNil(fixture.notice)
    }

    func testClearFinishedDeletesProcessingArtifactBeforeDeletingUnqueuedOperation() throws {
        let fixture = try CleanupFixture(queueExists: false)
        try fixture.createRegularArtifact(at: fixture.processing, data: Data("staged".utf8))
        fixture.restore()

        fixture.controller.clearFinishedActivities()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.processing.path))
        XCTAssertTrue(fixture.controller.activities.isEmpty)
        XCTAssertTrue(fixture.controller.operations.isEmpty)
        XCTAssertNil(fixture.notice)
    }

    func testRemoveActivityCleanupFailureRetainsOperationAndEveryArtifact() throws {
        let fixture = try CleanupFixture(queueExists: true)
        try fixture.createRegularArtifact(at: fixture.partial, data: Data("partial".utf8))
        try FileManager.default.createSymbolicLink(
            at: fixture.processing,
            withDestinationURL: fixture.outsideSentinel
        )
        fixture.restore()
        let original = try XCTUnwrap(fixture.controller.operations.first)

        fixture.controller.removeActivity(try XCTUnwrap(fixture.controller.activities.first))

        XCTAssertEqual(fixture.controller.operations, [original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partial.path))
        XCTAssertEqual(try Data(contentsOf: fixture.outsideSentinel), Data("outside".utf8))
        XCTAssertTrue(fixture.notice?.contains("Activity was kept") == true)
        XCTAssertTrue(fixture.notice?.contains("Symbolic links") == true)
    }

    func testClearFinishedCleanupFailureRetainsUnqueuedOperation() throws {
        let fixture = try CleanupFixture(queueExists: false)
        try FileManager.default.createDirectory(
            at: fixture.partial,
            withIntermediateDirectories: false
        )
        fixture.restore()
        let original = try XCTUnwrap(fixture.controller.operations.first)

        fixture.controller.clearFinishedActivities()

        XCTAssertEqual(fixture.controller.operations, [original])
        XCTAssertEqual(fixture.controller.activities.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partial.path))
        XCTAssertTrue(fixture.notice?.contains("Activity was kept") == true)
        XCTAssertTrue(fixture.notice?.contains("regular Library file") == true)
    }

    func testPendingTransactionRecoveryFailureRetainsActivityOwnership() throws {
        let fixture = try CleanupFixture(queueExists: false)
        let transaction = fixture.root.appendingPathComponent(
            ".orpheus-file-transaction-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        try Data("unexpected".utf8).write(to: transaction.appendingPathComponent("unknown"))
        fixture.restore()
        let original = try XCTUnwrap(fixture.controller.operations.first)

        fixture.controller.clearFinishedActivities()

        XCTAssertEqual(fixture.controller.operations, [original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertTrue(fixture.notice?.contains("Activity was kept") == true)
        XCTAssertTrue(fixture.notice?.contains("transaction folder") == true)
    }

    func testMismatchedCheckpointOutputRetainsActivityAndCoincidentalArtifact() throws {
        let fixture = try CleanupFixture(queueExists: false)
        let artifactData = Data("must not delete".utf8)
        try fixture.createRegularArtifact(at: fixture.partial, data: artifactData)
        fixture.restore { operation in
            operation.recordCheckpoint(QobuzDownloadCheckpoint(
                phase: .transferringAudio,
                trackID: QobuzID("track"),
                albumID: QobuzID("album"),
                outputURL: fixture.root.appendingPathComponent("unrelated.processing.flac")
            ))
        }

        fixture.controller.clearFinishedActivities()

        XCTAssertEqual(try Data(contentsOf: fixture.partial), artifactData)
        XCTAssertEqual(fixture.controller.operations.count, 1)
        XCTAssertEqual(fixture.controller.activities.count, 1)
        XCTAssertTrue(fixture.notice?.contains("Activity was kept") == true)
        XCTAssertTrue(fixture.notice?.contains("exact recovery-artifact identity") == true)
    }

    func testPreTransferFailureCanBeRemovedWithoutClaimingAnyArtifact() throws {
        let fixture = try CleanupFixture(queueExists: false)
        let coincidentalData = Data("not owned before transfer".utf8)
        try fixture.createRegularArtifact(at: fixture.partial, data: coincidentalData)
        fixture.restore { operation in
            operation.recordCheckpoint(QobuzDownloadCheckpoint(
                phase: .resolvingAudio,
                trackID: QobuzID("track"),
                albumID: QobuzID("album")
            ))
        }

        fixture.controller.clearFinishedActivities()

        XCTAssertEqual(try Data(contentsOf: fixture.partial), coincidentalData)
        XCTAssertTrue(fixture.controller.operations.isEmpty)
        XCTAssertTrue(fixture.controller.activities.isEmpty)
        XCTAssertNil(fixture.notice)
    }
}

@MainActor
private final class CleanupFixture {
    let sandbox: URL
    let root: URL
    let output: URL
    let processing: URL
    let partial: URL
    let outsideSentinel: URL
    let item = NativeQueueItem(request: .track(QobuzID("track")), title: "Track")
    let controller: NativeDownloadController
    private let operation: NativeDownloadOperation
    private(set) var notice: String?

    init(queueExists: Bool) throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativeDownloadActivityCleanupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        root = sandbox.appendingPathComponent("Library", isDirectory: true)
        output = root.appendingPathComponent("Artist/Album/01. Track.flac")
        processing = QobuzDownloadArtifacts.processingURL(
            for: output,
            formatID: QobuzAudioFormat.hiRes.formatID,
            albumID: QobuzID("album"),
            trackID: QobuzID("track")
        )
        partial = QobuzDownloadArtifacts.partialURL(
            for: output,
            formatID: QobuzAudioFormat.hiRes.formatID,
            albumID: QobuzID("album"),
            trackID: QobuzID("track")
        )
        outsideSentinel = sandbox.appendingPathComponent("outside.flac")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outsideSentinel)

        let queue = NativeQueueController()
        if queueExists { queue.restore(items: [item], selectedID: item.id) }
        controller = NativeDownloadController(
            queue: queue,
            connectivity: NativeConnectivityController(monitor: FakeConnectivityMonitor()),
            powerActivityManager: FakePowerActivityManager()
        )
        var operation = NativeDownloadOperation(
            queueID: item.id,
            activityID: UUID(),
            status: .failed("Interrupted"),
            title: item.title
        )
        operation.audioFormat = .hiRes
        operation.downloadRootPath = root.standardizedFileURL.path
        operation.recordOutput(output)
        operation.recordCheckpoint(QobuzDownloadCheckpoint(
            phase: .transferringAudio,
            trackID: QobuzID("track"),
            albumID: QobuzID("album"),
            outputURL: processing
        ))
        self.operation = operation
        controller.configureCallbacks(
            onNotice: { [weak self] in self?.notice = $0 },
            onRequireSettings: {},
            onIndexLibrary: { _, _ in },
            onCheckpoint: {}
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func createRegularArtifact(at url: URL, data: Data) throws {
        try data.write(to: url)
    }

    func restore(_ mutate: (inout NativeDownloadOperation) -> Void = { _ in }) {
        var restored = operation
        mutate(&restored)
        controller.restore(operations: [restored])
    }
}
