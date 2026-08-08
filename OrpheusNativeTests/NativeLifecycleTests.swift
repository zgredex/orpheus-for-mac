import AppKit
import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeLifecycleTests: XCTestCase {
    func testTerminationBeforeStartupNeverLoadsOrOverwritesPersistedSession() async {
        let item = NativeQueueItem(request: .album(QobuzID("untouched")), title: "Untouched")
        let original = NativeSessionSnapshot(
            queue: [item],
            operations: [NativeDownloadOperation(queueID: item.id)],
            selectedQueueID: item.id,
            linkInbox: []
        )
        let store = FailOnceSessionStore(snapshot: original)
        let fixture = NativeViewModelTestFixture(sessionStore: store)

        fixture.viewModel.prepareForTermination()
        await fixture.viewModel.start()

        XCTAssertEqual(store.loadCount, 0)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.snapshot, original)
    }

    func testTerminationDuringRestoreNeverOverwritesPersistedSession() async throws {
        let item = NativeQueueItem(request: .album(QobuzID("saved")), title: "Saved")
        let original = NativeSessionSnapshot(
            queue: [item],
            operations: [NativeDownloadOperation(queueID: item.id)],
            selectedQueueID: item.id,
            linkInbox: []
        )
        let store = BlockingSessionStore(snapshot: original)
        let fixture = NativeViewModelTestFixture(sessionStore: store)
        let startup = Task { await fixture.viewModel.start() }

        let didStartLoading = await eventually { store.loadStarted }
        XCTAssertTrue(didStartLoading)
        fixture.viewModel.prepareForTermination()
        store.releaseLoad()
        await startup.value

        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertTrue(fixture.viewModel.queue.isEmpty)
    }

    func testFailedSessionRestoreCanRetryWithoutDestroyingSnapshot() async throws {
        let item = NativeQueueItem(request: .album(QobuzID("retry")), title: "Retry")
        let original = NativeSessionSnapshot(
            queue: [item],
            operations: [NativeDownloadOperation(queueID: item.id)],
            selectedQueueID: item.id,
            linkInbox: []
        )
        let store = FailOnceSessionStore(snapshot: original)
        let fixture = NativeViewModelTestFixture(sessionStore: store)

        await fixture.viewModel.start()
        XCTAssertTrue(fixture.viewModel.canRetryStartup)
        XCTAssertFalse(fixture.viewModel.canInteractWithContent)
        XCTAssertTrue(fixture.viewModel.canEditConfiguration)
        XCTAssertTrue(fixture.viewModel.queue.isEmpty)
        XCTAssertEqual(store.saveCount, 0)

        await fixture.viewModel.start()
        XCTAssertFalse(fixture.viewModel.canRetryStartup)
        XCTAssertTrue(fixture.viewModel.canInteractWithContent)
        XCTAssertTrue(fixture.viewModel.canEditConfiguration)
        XCTAssertEqual(fixture.viewModel.queue.map(\.id), [item.id])
        XCTAssertEqual(store.snapshot, original)
    }

    func testOpenURLWaitsForSessionRestoreAndIsReplayedAfterward() async throws {
        let store = BlockingSessionStore(snapshot: nil)
        let fixture = NativeViewModelTestFixture(
            credentials: .complete,
            sessionStore: store
        )
        let startup = Task { await fixture.viewModel.start() }
        let didStartLoading = await eventually { store.loadStarted }
        XCTAssertTrue(didStartLoading)

        fixture.viewModel.handleOpenURL(try XCTUnwrap(URL(
            string: "https://open.qobuz.com/album/buffered-album"
        )))
        XCTAssertFalse(fixture.viewModel.browse.isOpen)

        store.releaseLoad()
        await startup.value

        XCTAssertTrue(fixture.viewModel.browse.isOpen)
        XCTAssertEqual(
            fixture.viewModel.browse.path.last?.destination,
            .album(QobuzID("buffered-album"))
        )
    }

    func testConfigurationMutationIsBlockedUntilRestoreCompletes() async {
        let store = BlockingSessionStore(snapshot: nil)
        let fixture = NativeViewModelTestFixture(sessionStore: store)
        let startup = Task { await fixture.viewModel.start() }
        let didStartLoading = await eventually { store.loadStarted }
        XCTAssertTrue(didStartLoading)

        XCTAssertFalse(fixture.viewModel.canEditConfiguration)
        XCTAssertThrowsError(
            try fixture.viewModel.saveConfiguration(fixture.viewModel.settingsDraft)
        )

        store.releaseLoad()
        await startup.value

        XCTAssertTrue(fixture.viewModel.canEditConfiguration)
    }

    func testTerminationCancelsValidationAndDiscardsLateRegion() async throws {
        let service = SlowValidationService()
        let fixture = NativeViewModelTestFixture(credentials: .complete, service: service)
        await fixture.viewModel.start()
        let didStartValidation = await eventually { service.validationStarted }
        XCTAssertTrue(didStartValidation)

        fixture.viewModel.prepareForTermination()
        let didCompleteValidation = await eventually { service.validationCompleted }
        XCTAssertTrue(didCompleteValidation)

        XCTAssertNil(fixture.viewModel.accountRegion)
        XCTAssertTrue(service.observedCancellation)
    }

    func testProcessTerminationObserverDoesNotDependOnAWindow() {
        let center = NotificationCenter()
        let name = Notification.Name("NativeLifecycleTests.terminate")
        var invocationCount = 0
        let observer = NativeApplicationTerminationObserver(
            center: center,
            notificationName: name
        ) {
            invocationCount += 1
        }

        center.post(name: name, object: nil)

        XCTAssertEqual(invocationCount, 1)
        withExtendedLifetime(observer) {}
    }

    private func eventually(
        _ predicate: @escaping () -> Bool,
        attempts: Int = 200
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private final class BlockingSessionStore: NativeSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadGate = DispatchSemaphore(value: 0)
    private var stored: NativeSessionSnapshot?
    private var didStart = false
    private var writes = 0

    init(snapshot: NativeSessionSnapshot?) {
        stored = snapshot
    }

    var loadStarted: Bool { lock.withLock { didStart } }
    var snapshot: NativeSessionSnapshot? { lock.withLock { stored } }
    var saveCount: Int { lock.withLock { writes } }

    func load() throws -> NativeSessionSnapshot? {
        lock.withLock { didStart = true }
        loadGate.wait()
        return snapshot
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        lock.withLock {
            stored = snapshot
            writes += 1
        }
    }

    func releaseLoad() {
        loadGate.signal()
    }
}

private final class FailOnceSessionStore: NativeSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeSessionSnapshot
    private var shouldFail = true
    private var loads = 0
    private var writes = 0

    init(snapshot: NativeSessionSnapshot) {
        stored = snapshot
    }

    var snapshot: NativeSessionSnapshot { lock.withLock { stored } }
    var loadCount: Int { lock.withLock { loads } }
    var saveCount: Int { lock.withLock { writes } }

    func load() throws -> NativeSessionSnapshot? {
        try lock.withLock {
            loads += 1
            if shouldFail {
                shouldFail = false
                throw NativeQobuzError.fileSystem("Injected transient session read failure.")
            }
            return stored
        }
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        lock.withLock {
            stored = snapshot
            writes += 1
        }
    }
}

private final class SlowValidationService: FakeQobuzService, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var completed = false
    private var cancelled = false

    var validationStarted: Bool { lock.withLock { started } }
    var validationCompleted: Bool { lock.withLock { completed } }
    var observedCancellation: Bool { lock.withLock { cancelled } }

    override func validateAccount() async throws -> String? {
        lock.withLock { started = true }
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            lock.withLock { cancelled = true }
        }
        lock.withLock { completed = true }
        return "US"
    }
}
