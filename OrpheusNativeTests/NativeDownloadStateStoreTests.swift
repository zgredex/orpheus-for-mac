import XCTest
import NativeQobuzCore
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeDownloadStateStoreTests: XCTestCase {
    func testOperationOwnsActivityTelemetryAndCompletionWaitsForLibraryIndex() {
        let (item, ledger, activityID) = preparedAlbumActivity()
        let output = URL(fileURLWithPath: "/Library/Artist/Album/01. Track.flac")
        let staging = URL(fileURLWithPath: "/Library/Artist/Album/.01. Track.qobuz-27.processing.flac")
        let asset = URL(fileURLWithPath: "/Library/Artist/Album/cover.jpg")

        ledger.handle(.warning("Cover unavailable"), activityID: activityID)
        ledger.handle(.assetCreated(asset), activityID: activityID)
        ledger.handle(.trackStarted(
            track: resolvedTrack(),
            destination: output,
            format: .hiRes
        ), activityID: activityID)
        ledger.handle(.checkpoint(QobuzDownloadCheckpoint(
            phase: .writingCollectionAssets,
            outputURL: staging
        )), activityID: activityID)
        ledger.handle(.completed(title: "Album", downloaded: 1, skipped: 0), activityID: activityID)

        let pending = ledger.operations.first
        XCTAssertEqual(pending?.status, .indexingLibrary)
        XCTAssertEqual(pending?.warnings, ["Cover unavailable"])
        XCTAssertEqual(pending?.outputURLs, [output])
        XCTAssertEqual(pending?.assetURLs, [asset])
        XCTAssertEqual(pending?.checkpoint?.phase, .writingCollectionAssets)
        XCTAssertEqual(ledger.activities.first?.phase, "Indexing Library")

        ledger.markLibraryIndexed(queueID: item.id, activityID: activityID)

        XCTAssertEqual(ledger.operations.first?.status, .completed)
        XCTAssertEqual(ledger.operations.first?.checkpoint?.phase, .complete)
        XCTAssertEqual(ledger.activities.first?.phase, "Complete with warnings")
    }

    func testOneOperationDrivesQueueAndActivityStatus() {
        let queueID = UUID()
        let activityID = UUID()
        var state = NativeDownloadStateStore()

        state.registerQueue(queueID)
        state.bindActivity(activityID, to: queueID)
        state.transition(queueID: queueID, to: .downloading)

        XCTAssertEqual(state.status(forQueueID: queueID), .downloading)
        XCTAssertEqual(state.status(forActivityID: activityID), .downloading)
        XCTAssertEqual(state.operations.first?.queueID, queueID)
        XCTAssertEqual(state.operations.first?.activityID, activityID)
        XCTAssertEqual(state.operations.first?.status, .downloading)
    }

    func testActivitiesUseQueueIDAsStableTieBreakerForEqualCreationDates() {
        let firstQueueID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondQueueID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let createdAt = Date(timeIntervalSince1970: 1_720_958_400)
        var first = NativeDownloadOperation(
            queueID: firstQueueID,
            activityID: UUID(),
            status: .paused,
            title: "First"
        )
        first.activityCreatedAt = createdAt
        var second = NativeDownloadOperation(
            queueID: secondQueueID,
            activityID: UUID(),
            status: .paused,
            title: "Second"
        )
        second.activityCreatedAt = createdAt

        let state = NativeDownloadStateStore(operations: [second, first])

        XCTAssertEqual(state.activities.map(\.queueID), [firstQueueID, secondQueueID])
    }

    func testInterruptedOperationsNormalizeTheirAuthoritativeActivityData() {
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

    func testRetryClearsAttemptTelemetryButPartialResumeKeepsOnlyRecoveryIdentity() throws {
        let (item, ledger, activityID) = preparedAlbumActivity()
        let output = URL(fileURLWithPath: "/Library/Artist/Album/01. Track.flac")
        ledger.handle(.trackStarted(
            track: resolvedTrack(),
            destination: output,
            format: .hiRes
        ), activityID: activityID)
        ledger.handle(.progress(QobuzDownloadProgress(
            completedTracks: 0,
            totalTracks: 1,
            currentTrackFraction: 0.5,
            overallFraction: 0.5,
            bytesWritten: 50,
            totalBytes: 100,
            bytesPerSecond: 10
        )), activityID: activityID)
        ledger.handle(.warning("old warning"), activityID: activityID)
        ledger.transition(queueID: item.id, activityID: activityID, to: .failed("old failure"))

        _ = ledger.prepareActivity(
            for: item,
            quality: .lossless,
            repairFormat: nil,
            root: URL(fileURLWithPath: "/Library")
        )

        let restarted = try XCTUnwrap(ledger.operations.first)
        XCTAssertEqual(restarted.activityID, activityID)
        XCTAssertEqual(restarted.quality, .lossless)
        XCTAssertEqual(restarted.progress, 0)
        XCTAssertEqual(restarted.completedTracks, 0)
        XCTAssertEqual(restarted.totalTracks, 0)
        XCTAssertNil(restarted.bytesWritten)
        XCTAssertNil(restarted.totalBytes)
        XCTAssertNil(restarted.currentTrack)
        XCTAssertNil(restarted.checkpoint)
        XCTAssertTrue(restarted.outputURLs.isEmpty)
        XCTAssertTrue(restarted.warnings.isEmpty)
        XCTAssertTrue(restarted.notices.isEmpty)
        XCTAssertNil(restarted.errorMessage)
    }

    func testSessionRejectsDuplicateOperationAndActivityBindings() throws {
        let queue = NativeQueueItem(request: .album(.init("album")), title: "Album")
        let valid = NativeDownloadOperation(
            queueID: queue.id,
            activityID: UUID(),
            status: .paused,
            title: queue.title
        )

        var duplicate = NativeSessionSnapshot(
            queue: [queue],
            operations: [valid, valid],
            selectedQueueID: queue.id,
            linkInbox: []
        )
        XCTAssertThrowsError(try duplicate.validate())

        let second = NativeQueueItem(request: .album(.init("second")), title: "Second")
        duplicate.queue.append(second)
        duplicate.operations = [valid, NativeDownloadOperation(
            queueID: second.id,
            activityID: valid.activityID,
            status: .paused,
            title: second.title
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
        try Data(
            #"{"schemaVersion":2,"queue":[],"operations":[],"selectedQueueID":null,"linkInbox":[]}"#.utf8
        )
            .write(to: paths.sessionURL)

        let restored = try NativeSessionStore(paths: paths).load()

        XCTAssertNil(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionURL.path))
        let rejected = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("download-session.rejected-") && $0.hasSuffix(".json") }
        XCTAssertEqual(rejected.count, 1)
    }

    func testSessionRestoreRejectsWritableRecoveryStateFromDifferentConfiguredRoot() async throws {
        let configuredRoot = URL(fileURLWithPath: "/Configured Library", isDirectory: true)
        let oldRoot = URL(fileURLWithPath: "/Old Library", isDirectory: true)
        let item = NativeQueueItem(request: .album(QobuzID("album")), title: "Album")
        var operation = NativeDownloadOperation(
            queueID: item.id,
            activityID: UUID(),
            status: .paused,
            title: item.title
        )
        operation.quality = .hiRes
        operation.downloadRootPath = oldRoot.path
        let output = oldRoot.appendingPathComponent("Artist/Album/01. Track.flac")
        operation.recordOutput(output)
        operation.recordCheckpoint(QobuzDownloadCheckpoint(
            phase: .transferringAudio,
            trackID: QobuzID("track"),
            albumID: QobuzID("album"),
            outputURL: QobuzDownloadArtifacts.processingURL(
                for: output,
                formatID: QobuzAudioFormat.hiRes.formatID,
                albumID: QobuzID("album"),
                trackID: QobuzID("track")
            )
        ))
        let store = MemorySessionStore(snapshot: singleItemSession(item: item, operation: operation))
        let queue = NativeQueueController()
        let downloads = NativeDownloadController(
            queue: queue,
            connectivity: NativeConnectivityController(monitor: FakeConnectivityMonitor()),
            powerActivityManager: FakePowerActivityManager()
        )
        let session = NativeSessionController(
            store: store,
            queue: queue,
            downloads: downloads,
            linkInbox: NativeLinkInboxController()
        )

        try await session.restore(root: configuredRoot)

        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertTrue(downloads.operations.isEmpty)
        XCTAssertNil(store.snapshot)
    }

    func testCompletedHistoricalActivityMayReferToPreviousLibraryRoot() throws {
        let item = NativeQueueItem(request: .track(QobuzID("track")), title: "Track")
        let oldRoot = URL(fileURLWithPath: "/Old Library", isDirectory: true)
        var operation = NativeDownloadOperation(
            queueID: item.id,
            activityID: UUID(),
            status: .completed,
            title: item.title
        )
        operation.downloadRootPath = oldRoot.path
        operation.recordOutput(oldRoot.appendingPathComponent("Artist/Album/01. Track.flac"))
        operation.recordCheckpoint(QobuzDownloadCheckpoint(phase: .complete))
        let snapshot = singleItemSession(item: item, operation: operation)

        XCTAssertNoThrow(try snapshot.validate())
        XCTAssertNoThrow(try snapshot.validate(
            restoringAt: URL(fileURLWithPath: "/Current Library", isDirectory: true)
        ))
    }

    func testSessionRequiresExactArtifactIdentityOnlyAfterTransferStarts() throws {
        let item = NativeQueueItem(request: .track(QobuzID("track")), title: "Track")
        let root = URL(fileURLWithPath: "/Library", isDirectory: true)
        var operation = NativeDownloadOperation(
            queueID: item.id,
            activityID: UUID(),
            status: .failed("Signed URL failed"),
            title: item.title
        )
        operation.quality = .hiRes
        operation.downloadRootPath = root.path
        operation.recordCheckpoint(QobuzDownloadCheckpoint(
            phase: .resolvingAudio,
            trackID: QobuzID("track"),
            albumID: QobuzID("album")
        ))

        XCTAssertNoThrow(try singleItemSession(item: item, operation: operation).validate())

        operation.recordCheckpoint(QobuzDownloadCheckpoint(
            phase: .transferringAudio,
            trackID: QobuzID("track"),
            albumID: QobuzID("album")
        ))
        XCTAssertThrowsError(try singleItemSession(item: item, operation: operation).validate())
    }

    private func preparedAlbumActivity() -> (NativeQueueItem, NativeDownloadLedger, UUID) {
        let item = NativeQueueItem(request: .album(.init("album")), title: "Album")
        let ledger = NativeDownloadLedger()
        ledger.registerQueue(item.id)
        let activityID = ledger.prepareActivity(
            for: item,
            quality: .hiRes,
            repairFormat: nil,
            root: URL(fileURLWithPath: "/Library")
        )
        return (item, ledger, activityID)
    }

    private func resolvedTrack() -> QobuzResolvedTrack {
        let albumID = QobuzID("album")
        return QobuzResolvedTrack(
            track: QobuzTrack(id: QobuzID("track"), title: "Track"),
            album: QobuzAlbum(
                id: albumID,
                title: "Album",
                artist: QobuzArtist(id: QobuzID("artist"), name: "Artist")
            ),
            collection: .album(id: albumID, title: "Album"),
            position: 1,
            total: 1
        )
    }
}
