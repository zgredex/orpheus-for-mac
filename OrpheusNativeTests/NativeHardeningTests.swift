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

        viewModel.start()
        for _ in 0..<100 where viewModel.archiveSnapshot == nil || viewModel.isArchiveScanning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.archiveSnapshot, rebuilt)
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(try NativeArchiveIndexStore(paths: paths).load(), .restored(rebuilt))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeHardeningTests-\(UUID().uuidString)", isDirectory: true)
    }
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
