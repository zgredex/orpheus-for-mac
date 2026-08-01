import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeHardeningTests: XCTestCase {
    func testStableOnlinePathGetsFallbackProbeWithoutPollingOrPathChange() async throws {
        let events = NativeConnectivityEvents()
        let started = Date()

        try await events.waitForOnline(
            after: 7,
            fallbackDelay: .milliseconds(20),
            currentState: { .online }
        )

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.015)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testSupersededArchiveRefreshCannotClearNewerScanState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let expected = QobuzArchiveSnapshot(
            rootPath: paths.defaultDownloadRoot.standardizedFileURL.path,
            tracks: [],
            issues: [QobuzArchiveIssue(relativePath: ".", message: "newest refresh")]
        )
        let scanner = SequencedArchiveScanner(finalSnapshot: expected)
        let viewModel = NativeViewModel(paths: paths, archiveScanner: scanner)

        viewModel.refreshArchive()
        try await Task.sleep(for: .milliseconds(20))
        viewModel.refreshArchive()
        try await Task.sleep(for: .milliseconds(190))

        XCTAssertTrue(viewModel.isArchiveScanning)
        XCTAssertNil(viewModel.archiveSnapshot)

        for _ in 0..<100 where viewModel.isArchiveScanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isArchiveScanning)
        XCTAssertEqual(viewModel.archiveSnapshot, expected)
        XCTAssertEqual(scanner.scanCount, 2)
    }

    func testArchiveCacheQuarantinesUnsafeRelativeTrackPaths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeArchiveIndexStore(paths: paths)
        let unsafe = QobuzArchiveTrack(
            relativePath: "../outside.flac",
            qobuzTrackID: "track",
            qobuzAlbumID: "album",
            formatID: 27,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: String(repeating: "a", count: 64),
            integrity: .verified,
            archiveKind: .album
        )
        try FileManager.default.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            QobuzArchiveSnapshot(rootPath: paths.defaultDownloadRoot.path, tracks: [unsafe])
        ).write(to: paths.archiveIndexURL)

        XCTAssertEqual(try store.load(), .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.archiveIndexURL.path))
        let rejected = try FileManager.default.contentsOfDirectory(
            at: paths.applicationSupportRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("archive-index.rejected-") }
        XCTAssertEqual(rejected.count, 1)
    }

    func testRejectedArchiveCacheRebuildsAutomaticallyAtStartup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let duplicate = QobuzArchiveTrack(
            relativePath: "Artist/Album/01.flac",
            qobuzTrackID: "track",
            qobuzAlbumID: "album",
            formatID: 27,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: String(repeating: "a", count: 64),
            integrity: .verified,
            archiveKind: .album
        )
        let invalid = QobuzArchiveSnapshot(
            rootPath: paths.defaultDownloadRoot.path,
            tracks: [duplicate, duplicate]
        )
        try FileManager.default.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(invalid).write(to: paths.archiveIndexURL)
        let rebuilt = QobuzArchiveSnapshot(rootPath: paths.defaultDownloadRoot.path, tracks: [])
        let scanner = ImmediateArchiveScanner(snapshot: rebuilt)
        let viewModel = NativeViewModel(paths: paths, archiveScanner: scanner)

        await viewModel.start()
        for _ in 0..<100 where viewModel.archiveSnapshot == nil || viewModel.isArchiveScanning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.archiveSnapshot, rebuilt)
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(try NativeArchiveIndexStore(paths: paths).load(), .restored(rebuilt))
    }

    func testInvalidationPreventsLateArchiveCacheFromRepopulatingLibrary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Music", isDirectory: true)
        let cached = QobuzArchiveSnapshot(
            rootPath: libraryRoot.standardizedFileURL.path,
            tracks: []
        )
        let scanner = ImmediateArchiveScanner(snapshot: cached)
        let controller = NativeLibraryController(
            archiveStore: DelayedArchiveStore(snapshot: cached, loadDelay: 0.1),
            scanner: scanner,
            adopter: QobuzLibraryAdopter(scanner: scanner)
        )

        let restoration = Task { await controller.loadCache(for: libraryRoot) }
        try await Task.sleep(for: .milliseconds(20))
        controller.invalidate()
        _ = await restoration.value

        XCTAssertNil(controller.snapshot)
    }

    func testSessionCacheSymlinkIsQuarantinedWithoutReadingOrChangingTarget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let outside = root.appendingPathComponent("outside-session.json")
        let paths = NativePaths(
            applicationSupportRoot: support,
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("private outside data".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: paths.sessionURL, withDestinationURL: outside)

        XCTAssertNil(try NativeSessionStore(paths: paths).load())
        XCTAssertEqual(try Data(contentsOf: outside), Data("private outside data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionURL.path))
        let rejected = try FileManager.default.contentsOfDirectory(atPath: support.path)
            .filter { $0.hasPrefix("download-session.rejected-") }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: support.appendingPathComponent(rejected[0]).path
            ),
            outside.path
        )
    }

    func testOversizedArchiveCacheIsRejectedWithoutAllocatingItsDeclaredSize() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        try FileManager.default.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.archiveIndexURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: paths.archiveIndexURL)
        try handle.truncate(atOffset: UInt64(NativePersistentArtifact.archiveIndex.maximumBytes + 1))
        try handle.close()

        XCTAssertEqual(try NativeArchiveIndexStore(paths: paths).load(), .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.archiveIndexURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.applicationSupportRoot.path)
                .filter { $0.hasPrefix("archive-index.rejected-") }
                .count,
            1
        )
    }

    func testSessionWriterCoalescesPendingSnapshotsAndSkipsUnchangedFlush() throws {
        let store = RecordingSessionStore(saveDelay: 0.05)
        let writer = NativeSessionPersistenceWriter(store: store)
        let first = sessionSnapshot(inboxCount: 1)
        let second = sessionSnapshot(inboxCount: 2)
        let final = sessionSnapshot(inboxCount: 3)
        let started = Date()

        writer.enqueue(first) { _ in }
        writer.enqueue(second) { _ in }
        writer.enqueue(final) { _ in }

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.03)
        try writer.flush(final)
        let writesAfterFlush = store.saveCount
        try writer.flush(final)

        XCTAssertEqual(store.snapshot, final)
        XCTAssertLessThanOrEqual(writesAfterFlush, 2)
        XCTAssertEqual(store.saveCount, writesAfterFlush)
    }

    private func sessionSnapshot(inboxCount: Int) -> NativeSessionSnapshot {
        NativeSessionSnapshot(
            queue: [],
            operations: [],
            selectedQueueID: nil,
            linkInbox: (0..<inboxCount).map { index in
                NativeLinkInboxItem(link: ParsedQobuzLink(
                    original: "https://open.qobuz.com/album/\(index)",
                    request: .album(QobuzID(String(index)))
                ))
            }
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeHardeningTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RecordingSessionStore: NativeSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let saveDelay: TimeInterval
    private var stored: NativeSessionSnapshot?
    private var writes = 0

    init(saveDelay: TimeInterval) {
        self.saveDelay = saveDelay
    }

    var snapshot: NativeSessionSnapshot? { lock.withLock { stored } }
    var saveCount: Int { lock.withLock { writes } }

    func load() throws -> NativeSessionSnapshot? {
        snapshot
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        Thread.sleep(forTimeInterval: saveDelay)
        lock.withLock {
            stored = snapshot
            writes += 1
        }
    }
}

private final class DelayedArchiveStore: NativeArchiveIndexStoring, @unchecked Sendable {
    private let snapshot: QobuzArchiveSnapshot
    private let loadDelay: TimeInterval

    init(snapshot: QobuzArchiveSnapshot, loadDelay: TimeInterval) {
        self.snapshot = snapshot
        self.loadDelay = loadDelay
    }

    func load() throws -> NativeArchiveIndexLoadResult {
        Thread.sleep(forTimeInterval: loadDelay)
        return .restored(snapshot)
    }

    func save(_ snapshot: QobuzArchiveSnapshot) throws {}
}

private final class ImmediateArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    private let snapshot: QobuzArchiveSnapshot
    private let lock = NSLock()
    private var scans = 0

    init(snapshot: QobuzArchiveSnapshot) {
        self.snapshot = snapshot
    }

    var scanCount: Int { lock.withLock { scans } }

    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        lock.withLock { scans += 1 }
        return snapshot
    }
}

private final class SequencedArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    private let finalSnapshot: QobuzArchiveSnapshot
    private let lock = NSLock()
    private var scans = 0

    init(finalSnapshot: QobuzArchiveSnapshot) {
        self.finalSnapshot = finalSnapshot
    }

    var scanCount: Int {
        lock.withLock { scans }
    }

    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        let call = lock.withLock {
            scans += 1
            return scans
        }
        await nonCancellingDelay(milliseconds: call == 1 ? 120 : 320)
        if call == 1 { throw NativeQobuzError.cancelled }
        return finalSnapshot
    }

    private func nonCancellingDelay(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
