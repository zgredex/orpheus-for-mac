import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeLibraryAdoptionActivationTests: XCTestCase {
    func testCoordinatorOwnsPreparationCommitPresentationAndPublication() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }
        fixture.adopter.preparedAdoption = fixture.pending.prepared
        let coordinator = NativeLibraryAdoptionCoordinator(
            account: fixture.account,
            library: fixture.library
        )

        let outcome = try await coordinator.adopt(
            at: fixture.candidate,
            draft: SettingsDraft(
                credentials: .complete,
                quality: .hiRes,
                downloadPath: fixture.candidate.path
            ),
            downloadIsActive: false,
            mutationsBlocked: false
        )

        XCTAssertEqual(outcome.notice, "Existing Library adopted and its index was rebuilt.")
        XCTAssertEqual(fixture.configuration.configuration.settings.downloadPath, fixture.candidate.path)
        XCTAssertEqual(fixture.library.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.adopter.calls, [.prepare, .prepareCommit, .finishCommit])

        coordinator.publish(outcome)
        XCTAssertEqual(fixture.library.snapshot, fixture.candidateSnapshot)
        XCTAssertTrue(fixture.library.isOpen)
    }

    func testActivationCommitsCacheConfigurationManifestAndThenPublishes() throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }

        let committed = try fixture.activator.commit(
            fixture.pending,
            credentials: .complete,
            quality: .hiRes,
            downloadIsActive: false
        )

        XCTAssertEqual(fixture.configuration.configuration.settings.downloadPath, fixture.candidate.path)
        XCTAssertEqual(fixture.archive.snapshot, fixture.candidateSnapshot)
        XCTAssertEqual(fixture.library.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.adopter.calls, [.prepareCommit, .finishCommit])
        XCTAssertFalse(committed.cleanupPending)

        fixture.library.publishActivation(committed.staged)
        XCTAssertEqual(fixture.library.snapshot, fixture.candidateSnapshot)
        XCTAssertTrue(fixture.library.isOpen)
    }

    func testCacheStageFailureRestoresManifestAndLeavesConfigurationUntouched() throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }
        fixture.archive.failNextSave()

        XCTAssertThrowsError(try fixture.activate())

        XCTAssertEqual(fixture.configuration.configuration.settings.downloadPath, fixture.oldRoot.path)
        XCTAssertEqual(fixture.archive.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.library.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.adopter.calls, [.rollback])
    }

    func testManifestCommitPreparationFailureRestoresCacheAndManifest() throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }
        fixture.adopter.prepareCommitFailure = ActivationFailure.injected

        XCTAssertThrowsError(try fixture.activate())

        XCTAssertEqual(fixture.configuration.saveCount, 0)
        XCTAssertEqual(fixture.archive.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.adopter.calls, [.prepareCommit, .rollback])
    }

    func testConfigurationFailureRestoresCacheAndManifestWithoutPublishingCandidate() throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }
        fixture.configuration.failNextSave()

        XCTAssertThrowsError(try fixture.activate())

        XCTAssertEqual(fixture.configuration.configuration.settings.downloadPath, fixture.oldRoot.path)
        XCTAssertEqual(fixture.archive.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.library.snapshot, fixture.oldSnapshot)
        XCTAssertEqual(fixture.adopter.calls, [.prepareCommit, .rollback])
    }

    func testCommittedConfigurationKeepsExplicitMarkerWhenCleanupFails() throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }
        fixture.adopter.finishCommitFailure = ActivationFailure.injected

        let committed = try fixture.activate()

        XCTAssertTrue(committed.cleanupPending)
        XCTAssertEqual(fixture.configuration.configuration.settings.downloadPath, fixture.candidate.path)
        XCTAssertEqual(fixture.archive.snapshot, fixture.candidateSnapshot)
        XCTAssertEqual(fixture.adopter.calls, [.prepareCommit, .finishCommit])
    }

    func testRollbackReportsEveryFailedOwnerAndPreservesCandidateCacheForRecovery() throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanup() }
        fixture.configuration.failNextSave()
        fixture.adopter.rollbackFailure = ActivationFailure.injected
        fixture.adopter.onPrepareCommit = { fixture.archive.failNextSave() }

        XCTAssertThrowsError(try fixture.activate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Library manifest"))
            XCTAssertTrue(error.localizedDescription.contains("archive cache"))
            XCTAssertTrue(error.localizedDescription.contains("Recovery markers were preserved"))
        }
        XCTAssertEqual(fixture.archive.snapshot, fixture.candidateSnapshot)
        XCTAssertEqual(fixture.configuration.configuration.settings.downloadPath, fixture.oldRoot.path)
    }
}

@MainActor
private final class ActivationFixture {
    let root: URL
    let oldRoot: URL
    let candidate: URL
    let oldSnapshot: QobuzArchiveSnapshot
    let candidateSnapshot: QobuzArchiveSnapshot
    let configuration: MemoryConfigurationStore
    let archive: MemoryArchiveStore
    let adopter = RecordingLibraryAdopter()
    let account: NativeAccountController
    let library: NativeLibraryController
    let activator: NativeLibraryAdoptionActivationController
    let pending: NativePendingLibraryAdoption

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeLibraryActivationTests-\(UUID().uuidString)", isDirectory: true)
        oldRoot = root.appendingPathComponent("Old", isDirectory: true)
        candidate = root.appendingPathComponent("Candidate", isDirectory: true)
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
            defaultDownloadRoot: oldRoot
        )
        oldSnapshot = QobuzArchiveSnapshot(rootPath: oldRoot.path, tracks: [])
        candidateSnapshot = QobuzArchiveSnapshot(rootPath: candidate.path, tracks: [])
        configuration = MemoryConfigurationStore(
            paths: paths,
            settings: NativeSettings(downloadPath: oldRoot.path, quality: .hiRes)
        )
        archive = MemoryArchiveStore(snapshot: oldSnapshot)
        account = NativeAccountController(
            paths: paths,
            configurationStore: configuration,
            clientFactory: { _ in FakeQobuzService() }
        )
        library = NativeLibraryController(
            archiveStore: archive,
            scanner: EmptyArchiveScanner(),
            adopter: adopter
        )
        try library.install(oldSnapshot, open: false)
        activator = NativeLibraryAdoptionActivationController(account: account, library: library)
        let plan = QobuzLibraryAdoptionPlan(
            root: candidate,
            snapshot: candidateSnapshot,
            manifestAction: .update,
            existingCollectionCount: 1,
            proposedManifest: QobuzLibraryManifest()
        )
        pending = NativePendingLibraryAdoption(
            id: "activation-test",
            prepared: QobuzPreparedLibraryAdoption(
                result: QobuzLibraryAdoptionResult(plan: plan, snapshot: candidateSnapshot)
            )
        )
    }

    func activate() throws -> NativeCommittedLibraryAdoption {
        try activator.commit(
            pending,
            credentials: .complete,
            quality: .hiRes,
            downloadIsActive: false
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingLibraryAdopter: QobuzLibraryAdopting, @unchecked Sendable {
    enum Call: Equatable { case prepare, prepareCommit, finishCommit, rollback }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var prepareCommitFailure: Error?
    var finishCommitFailure: Error?
    var rollbackFailure: Error?
    var onPrepareCommit: (() -> Void)?
    var preparedAdoption: QobuzPreparedLibraryAdoption?

    var calls: [Call] { lock.withLock { recorded } }

    func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan {
        throw ActivationFailure.unused
    }

    func prepare(root: URL) async throws -> QobuzPreparedLibraryAdoption {
        record(.prepare)
        guard let preparedAdoption else { throw ActivationFailure.unused }
        return preparedAdoption
    }

    func prepareCommit(_ adoption: QobuzPreparedLibraryAdoption) throws {
        record(.prepareCommit)
        onPrepareCommit?()
        if let prepareCommitFailure { throw prepareCommitFailure }
    }

    func finishCommit(_ adoption: QobuzPreparedLibraryAdoption) throws {
        record(.finishCommit)
        if let finishCommitFailure { throw finishCommitFailure }
    }

    func rollback(_ adoption: QobuzPreparedLibraryAdoption) throws {
        record(.rollback)
        if let rollbackFailure { throw rollbackFailure }
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }
}

private struct EmptyArchiveScanner: QobuzArchiveScanning, Sendable {
    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        QobuzArchiveSnapshot(rootPath: root.standardizedFileURL.path, tracks: [])
    }
}

private enum ActivationFailure: Error {
    case injected
    case unused
}
