import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeLibraryIndexRecoveryTests: XCTestCase {
    func testRestartedIndexingCompletesLocallyWithoutCredentialsOrClient() async throws {
        let fixture = try RecoveryFixture()
        let completed = expectation(description: "local Library index completed")
        var indexedRoot: URL?
        var indexedOutputs: [URL] = []
        fixture.controller.configureCallbacks(
            onNotice: { _ in },
            onRequireSettings: { XCTFail("Local recovery must not require credentials") },
            onIndexLibrary: { root, outputs in
                indexedRoot = root
                indexedOutputs = outputs
            },
            onCheckpoint: {
                if fixture.controller.status(forQueueID: fixture.item.id) == .completed {
                    completed.fulfill()
                }
            }
        )

        XCTAssertEqual(fixture.controller.status(forQueueID: fixture.item.id), .paused)
        fixture.startWithoutQobuz()
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(indexedRoot, fixture.libraryRoot)
        XCTAssertEqual(indexedOutputs, [fixture.output])
        XCTAssertEqual(fixture.controller.operations.first?.checkpoint?.phase, .complete)
        XCTAssertEqual(fixture.controller.operations.first?.warnings, ["Preserved warning"])
        XCTAssertEqual(fixture.controller.operations.first?.outputURLs, [fixture.output])
        XCTAssertTrue(fixture.power.beginReasons.isEmpty)
    }

    func testFailedLocalIndexRetryKeepsReceiptAndNeverCreatesTransferEngine() async throws {
        let fixture = try RecoveryFixture()
        let failed = expectation(description: "first local index failed")
        let completed = expectation(description: "local index retry completed")
        var attempt = 0
        var observedFailure = false
        fixture.controller.configureCallbacks(
            onNotice: { _ in },
            onRequireSettings: { XCTFail("Local recovery must not require credentials") },
            onIndexLibrary: { _, _ in
                attempt += 1
                if attempt == 1 {
                    throw NativeQobuzError.fileSystem("Injected archive-cache failure")
                }
            },
            onCheckpoint: {
                switch fixture.controller.status(forQueueID: fixture.item.id) {
                case .failed where !observedFailure:
                    observedFailure = true
                    failed.fulfill()
                case .completed: completed.fulfill()
                default: break
                }
            }
        )

        fixture.startWithoutQobuz()
        await fulfillment(of: [failed], timeout: 1)
        let failedOperation = try XCTUnwrap(fixture.controller.operations.first)
        XCTAssertEqual(failedOperation.checkpoint?.phase, .indexingLibrary)
        XCTAssertEqual(failedOperation.outputURLs, [fixture.output])
        XCTAssertEqual(failedOperation.warnings, ["Preserved warning"])

        fixture.startWithoutQobuz()
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(fixture.controller.status(forQueueID: fixture.item.id), .completed)
        XCTAssertTrue(fixture.power.beginReasons.isEmpty)
    }

    func testSymlinkedRecoveredOutputFailsClosedWithoutScanningOrRedownloading() async throws {
        let fixture = try RecoveryFixture(outputKind: .symbolicLink)
        let rejected = expectation(description: "unsafe receipt rejected")
        var indexCount = 0
        fixture.controller.configureCallbacks(
            onNotice: { _ in },
            onRequireSettings: { XCTFail("Invalid local recovery must not fall back to Qobuz") },
            onIndexLibrary: { _, _ in indexCount += 1 },
            onCheckpoint: {
                if case .failed = fixture.controller.status(forQueueID: fixture.item.id) {
                    rejected.fulfill()
                }
            }
        )

        fixture.startWithoutQobuz()
        await fulfillment(of: [rejected], timeout: 1)

        XCTAssertEqual(indexCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.outsideSentinel), Data("sentinel".utf8))
        XCTAssertEqual(fixture.controller.operations.first?.checkpoint?.phase, .indexingLibrary)
        XCTAssertTrue(fixture.power.beginReasons.isEmpty)
    }

    func testEmptyLibraryIndexReceiptIsRejectedBeforeIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EmptyLibraryIndexReceipt-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var operation = NativeDownloadOperation(
            queueID: UUID(),
            activityID: UUID(),
            status: .indexingLibrary,
            title: "Empty"
        )
        operation.downloadRootPath = root.path
        operation.recordCheckpoint(QobuzDownloadCheckpoint(phase: .indexingLibrary))

        XCTAssertFalse(operation.hasLibraryIndexReceipt)
        XCTAssertThrowsError(try operation.validateStoredLibraryPaths())
        do {
            _ = try await NativeLibraryIndexReceiptValidator().validate(operation)
            XCTFail("An empty receipt should not reach Library indexing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recovery receipt"))
        }
    }

    func testDownloadedIndexerRejectsUnverifiedChangedOutputBeforeCacheSave() async throws {
        let fixture = try DownloadedIndexerFixture(integrity: .checksumMismatch, managed: true)
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.index()
            XCTFail("Unverified output should be rejected")
        } catch {}

        XCTAssertNil(fixture.store.snapshot)
    }

    func testDownloadedIndexerRejectsUnmanagedChangedOutputBeforeCacheSave() async throws {
        let fixture = try DownloadedIndexerFixture(integrity: .verified, managed: false)
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.index()
            XCTFail("Unmanaged output should be rejected")
        } catch {}

        XCTAssertNil(fixture.store.snapshot)
    }

    func testDownloadedIndexerAllowsUnrelatedExistingProblems() async throws {
        let fixture = try DownloadedIndexerFixture(
            integrity: .verified,
            managed: true,
            unrelatedIssue: QobuzArchiveIssue(
                relativePath: "Existing/Broken.flac",
                message: "Existing unrelated problem"
            )
        )
        defer { fixture.cleanup() }

        let indexed = try await fixture.index()

        XCTAssertEqual(indexed.issues.count, 1)
        XCTAssertEqual(fixture.store.snapshot, indexed)
    }
}

private struct DownloadedIndexerFixture {
    let root: URL
    let output: URL
    let store = MemoryArchiveStore()
    let snapshot: QobuzArchiveSnapshot

    init(
        integrity: QobuzArchiveIntegrity,
        managed: Bool,
        unrelatedIssue: QobuzArchiveIssue? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DownloadedIndexerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        output = root.appendingPathComponent("Artist/Album/01. Track.flac")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data("audio".utf8)
        try data.write(to: output)
        let digest = MusicFileIntegrity.sha256(of: data)
        snapshot = QobuzArchiveSnapshot(
            rootPath: root.standardizedFileURL.path,
            tracks: [QobuzArchiveTrack(
                relativePath: "Artist/Album/01. Track.flac",
                qobuzTrackID: "track",
                qobuzAlbumID: "album",
                formatID: QobuzAudioFormat.lossless.formatID,
                expectedSHA256: digest,
                actualSHA256: integrity == .verified ? digest : nil,
                byteCount: Int64(data.count),
                integrity: integrity,
                archiveKind: .album,
                isLibraryManaged: managed
            )],
            issues: [unrelatedIssue].compactMap { $0 }
        )
    }

    func index() async throws -> QobuzArchiveSnapshot {
        try await NativeDownloadedLibraryIndexer(
            archiveStore: store,
            scanner: FakeArchiveScanner(snapshot: snapshot)
        ).index(root: root, reusing: nil, changedAudioURLs: [output])
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class RecoveryFixture {
    enum OutputKind { case regularFile, symbolicLink }

    let sandbox: URL
    let libraryRoot: URL
    let output: URL
    let outsideSentinel: URL
    let item: NativeQueueItem
    let controller: NativeDownloadController
    let power = FakePowerActivityManager()

    init(outputKind: OutputKind = .regularFile) throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativeLibraryIndexRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        libraryRoot = sandbox.appendingPathComponent("Library", isDirectory: true)
        output = libraryRoot.appendingPathComponent("Artist/Album/01. Track.flac")
        outsideSentinel = sandbox.appendingPathComponent("outside.flac")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(to: outsideSentinel)
        switch outputKind {
        case .regularFile:
            try Data("audio".utf8).write(to: output)
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outsideSentinel)
        }

        item = NativeQueueItem(request: .album(QobuzID("album")), title: "Album")
        let queue = NativeQueueController()
        queue.restore(items: [item], selectedID: item.id)
        controller = NativeDownloadController(
            queue: queue,
            connectivity: NativeConnectivityController(monitor: FakeConnectivityMonitor()),
            powerActivityManager: power
        )
        var operation = NativeDownloadOperation(
            queueID: item.id,
            activityID: UUID(),
            status: .indexingLibrary,
            title: item.title
        )
        operation.quality = .hiRes
        operation.downloadRootPath = libraryRoot.standardizedFileURL.path
        operation.warnings = ["Preserved warning"]
        operation.recordOutput(output)
        operation.recordCheckpoint(QobuzDownloadCheckpoint(phase: .indexingLibrary))
        controller.restore(operations: [operation])
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func startWithoutQobuz() {
        controller.start(
            ids: [item.id],
            client: nil,
            credentialsConfigured: false,
            defaultQuality: .hiRes,
            defaultRootPath: sandbox.appendingPathComponent("Wrong Root").path
        )
    }
}
