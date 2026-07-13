import XCTest
import NativeQobuzCore
@testable import OrpheusNative

@MainActor
final class NativeAdapterTests: XCTestCase {
    func testSettingsStoreUsesIsolatedRootAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("OrpheusNativePreview"),
            defaultDownloadRoot: root.appendingPathComponent("Downloads")
        )
        let store = NativeSettingsStore(paths: paths)

        let initial = try store.load()
        XCTAssertEqual(initial.downloadPath, paths.defaultDownloadRoot.path)
        XCTAssertEqual(initial.quality, .hiRes)
        XCTAssertTrue(paths.settingsURL.path.contains("OrpheusNativePreview"))
        XCTAssertFalse(paths.settingsURL.path.contains("OrpheusUI/OrpheusDL"))

        let changed = NativeSettings(downloadPath: root.appendingPathComponent("Music").path, quality: .mp3)
        try store.save(changed)
        XCTAssertEqual(try store.load(), changed)
    }

    func testCredentialStoreRoundTripsWithOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = FileCredentialStore(paths: paths)

        XCTAssertNil(try store.load())
        try store.save(.complete)

        XCTAssertEqual(try store.load(), .complete)
        XCTAssertEqual(try permissions(at: paths.applicationSupportRoot), 0o700)
        XCTAssertEqual(try permissions(at: paths.credentialsURL), 0o600)
        XCTAssertTrue(paths.credentialsURL.path.hasPrefix(paths.applicationSupportRoot.path))
    }

    func testDownloadSessionStoreRoundTripsQueueActivityQualityAndRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeSessionStore(paths: paths)
        var item = NativeQueueItem(request: .album(QobuzID("album")), title: "Album")
        item.status = .paused
        item.downloadQuality = .hiRes
        item.downloadRootPath = paths.defaultDownloadRoot.path
        var activity = NativeDownloadActivity(id: UUID(), queueID: item.id, title: item.title)
        activity.status = .paused
        activity.phase = "Paused after interruption"
        activity.progress = 0.42
        activity.bytesWritten = 42
        activity.totalBytes = 100
        let snapshot = NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            selectedQueueID: item.id
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertTrue(paths.sessionURL.path.hasPrefix(paths.applicationSupportRoot.path))
    }

    func testViewModelRestoresInterruptedDownloadAsPaused() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        var item = NativeQueueItem(request: .album(QobuzID("album")), title: "Interrupted Album")
        item.status = .downloading
        item.downloadQuality = .lossless
        item.downloadRootPath = paths.defaultDownloadRoot.path
        var activity = NativeDownloadActivity(id: UUID(), queueID: item.id, title: item.title)
        activity.status = .downloading
        activity.phase = "Downloading"
        activity.progress = 0.35
        activity.bytesPerSecond = 1_000
        let sessionStore = MemorySessionStore(snapshot: NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            selectedQueueID: item.id
        ))
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            sessionStore: sessionStore
        )

        viewModel.start()

        XCTAssertEqual(viewModel.queue.first?.status, .paused)
        XCTAssertEqual(viewModel.queue.first?.downloadQuality, .lossless)
        XCTAssertEqual(viewModel.queue.first?.downloadRootPath, paths.defaultDownloadRoot.path)
        XCTAssertEqual(viewModel.activities.first?.status, .paused)
        XCTAssertEqual(viewModel.activities.first?.phase, "Paused after interruption")
        XCTAssertNil(viewModel.activities.first?.bytesPerSecond)
        XCTAssertEqual(viewModel.selectedQueueID, item.id)
        XCTAssertFalse(viewModel.canClearActivity)
        XCTAssertEqual(sessionStore.snapshot?.queue.first?.status, .paused)
    }

    func testArchiveIndexStoreUsesApplicationSupportAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeArchiveIndexStore(paths: paths)
        let snapshot = QobuzArchiveSnapshot(
            rootPath: paths.defaultDownloadRoot.path,
            tracks: [Self.archiveTrack(relativePath: "Artist/Album/01.flac")]
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertTrue(paths.archiveIndexURL.path.hasPrefix(paths.applicationSupportRoot.path))
    }

    func testViewModelAddsSeveralLinksAndSkipsCanonicalDuplicates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore()
        )

        viewModel.addText("""
        https://open.qobuz.com/album/a
        https://play.qobuz.com/track/t
        https://open.qobuz.com/album/a
        """)

        XCTAssertEqual(viewModel.queue.map(\.request), [.album(.init("a")), .track(.init("t"))])
        XCTAssertEqual(viewModel.selectedQueueID, viewModel.queue.first?.id)
    }

    func testAdeleSearchPopulatesVisibleBrowseStateAndPreservesSelectedCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in service }
        )

        viewModel.start()
        viewModel.search("adele")
        viewModel.browseCategory = .tracks

        for _ in 0..<100 where viewModel.isBrowseLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(viewModel.isBrowseOpen)
        XCTAssertEqual(viewModel.browseQuery, "adele")
        XCTAssertEqual(viewModel.browseAlbums.map(\.title), ["30", "19"])
        XCTAssertEqual(viewModel.browseArtists.map(\.name), ["Adele"])
        XCTAssertEqual(viewModel.browseTracks.map(\.title), ["Hello"])
        XCTAssertEqual(viewModel.browseCategory, .tracks)
        XCTAssertEqual(viewModel.browseStatusText, "4 results")
        XCTAssertFalse(viewModel.isBrowseLoading)
    }

    func testBrowseDrillDownOpensAlbumPageAndBackReturnsToResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in service }
        )

        viewModel.start()
        viewModel.search("adele")
        viewModel.openAlbum(QobuzID("30"))
        XCTAssertEqual(viewModel.browsePath.count, 1)
        XCTAssertEqual(viewModel.browsePath.last?.content, .loading)

        for _ in 0..<100 where viewModel.browsePath.last?.content == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .album(let album)? = viewModel.browsePath.last?.content else {
            return XCTFail("Expected a loaded album page")
        }
        XCTAssertEqual(album.title, "30")
        XCTAssertEqual(album.tracks.map(\.title), ["Easy On Me"])

        viewModel.browseBack()
        XCTAssertTrue(viewModel.browsePath.isEmpty)
        XCTAssertTrue(viewModel.isBrowseOpen)

        viewModel.openAlbum(QobuzID("30"))
        viewModel.search("adele")
        XCTAssertTrue(viewModel.browsePath.isEmpty)
    }

    func testArtistPreviewReportsOfficialReleaseCountInsteadOfCreditedCatalogTotal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in service }
        )

        viewModel.start()
        viewModel.addRequest(.artist(QobuzID("adele")), title: "Adele")

        for _ in 0..<100 where viewModel.preview == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .artist(let catalog) = viewModel.preview else {
            return XCTFail("Expected an artist preview")
        }
        XCTAssertEqual(catalog.officialAlbums.count, 1)
        XCTAssertEqual(catalog.appearanceAlbums.count, 1)
        XCTAssertEqual(viewModel.queue.first?.subtitle, "1 official release")
    }

    func testBulkAlbumQueueSkipsDuplicatesAndUnavailableEditions() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore()
        )
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        let first = QobuzAlbum(id: QobuzID("first"), title: "First", artist: artist)
        let second = QobuzAlbum(id: QobuzID("second"), title: "Second", artist: artist)
        let blocked = QobuzAlbum(
            id: QobuzID("blocked"),
            title: "Blocked",
            artist: artist,
            streamable: false
        )

        viewModel.addRequest(.album(first.id), title: first.title)
        viewModel.addAlbums([first, second, second, blocked])

        XCTAssertEqual(viewModel.queue.map(\.request), [.album(first.id), .album(second.id)])
        XCTAssertEqual(viewModel.selectedQueueItem?.request, .album(second.id))
        XCTAssertEqual(viewModel.notice, "Skipped 2 already queued editions.")
    }

    func testOpeningLibraryRefreshesAndPersistsExactArchiveSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let snapshot = QobuzArchiveSnapshot(
            rootPath: paths.defaultDownloadRoot.path,
            tracks: [Self.archiveTrack(relativePath: "Artist/Album/01.flac")]
        )
        let archiveStore = MemoryArchiveStore()
        let archiveScanner = FakeArchiveScanner(snapshot: snapshot)
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            archiveStore: archiveStore,
            archiveScanner: archiveScanner
        )
        viewModel.start()

        viewModel.openLibrary()
        for _ in 0..<100 where viewModel.isArchiveScanning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(viewModel.isLibraryOpen)
        XCTAssertEqual(viewModel.archiveSnapshot, snapshot)
        XCTAssertEqual(archiveStore.snapshot, snapshot)
        XCTAssertEqual(archiveScanner.scanCount, 1)

        viewModel.closeLibrary()
        viewModel.openLibrary()
        for _ in 0..<100 where viewModel.isArchiveScanning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(archiveScanner.scanCount, 2)
    }

    func testCachedArchiveStatusUsesExactIDsAndBecomesCompleteAfterAlbumPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let snapshot = QobuzArchiveSnapshot(
            rootPath: paths.defaultDownloadRoot.path,
            tracks: [Self.archiveTrack(
                relativePath: "Adele/30/01.flac",
                trackID: "easy",
                albumID: "30"
            )]
        )
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            archiveStore: MemoryArchiveStore(snapshot: snapshot),
            clientFactory: { _ in FakeQobuzService() }
        )

        viewModel.start()
        let summary = QobuzAlbumSummary(id: QobuzID("30"), title: "30")
        XCTAssertEqual(viewModel.libraryStatus(for: summary), .indexed(verified: 1, problems: 0))

        viewModel.addRequest(.album(QobuzID("30")), title: "30")
        for _ in 0..<100 where viewModel.preview == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard let item = viewModel.queue.first else { return XCTFail("Expected queued album") }
        XCTAssertEqual(item.expectedTrackIDs, [QobuzID("easy")])
        XCTAssertEqual(viewModel.libraryStatus(for: item), .verified)
    }

    func testCachedArchiveForAnotherDownloadRootIsIgnored() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let snapshot = QobuzArchiveSnapshot(
            rootPath: root.appendingPathComponent("SomewhereElse").path,
            tracks: [Self.archiveTrack(relativePath: "track.flac")]
        )
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            archiveStore: MemoryArchiveStore(snapshot: snapshot)
        )

        viewModel.start()

        XCTAssertNil(viewModel.archiveSnapshot)
        XCTAssertNil(viewModel.libraryStatus(for: QobuzAlbumSummary(id: QobuzID("album-id"), title: "Album")))
    }

    func testRepairStagingKeepsExactTargetAndSkipsVerifiedUnsupportedAndDuplicateRows() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore()
        )
        let damaged = Self.archiveTrack(
            relativePath: "Artist/Album/01.flac",
            trackID: "damaged",
            albumID: "album",
            integrity: .checksumMismatch
        )
        let verified = Self.archiveTrack(
            relativePath: "Artist/Album/02.flac",
            trackID: "verified",
            albumID: "album"
        )
        let unsupported = Self.archiveTrack(
            relativePath: "Artist/Album/03.flac",
            trackID: "unsupported",
            albumID: "album",
            formatID: 999,
            integrity: .missing
        )

        let firstIDs = viewModel.stageArchiveRepairs([damaged, damaged, verified, unsupported])
        let secondIDs = viewModel.stageArchiveRepairs([damaged])

        XCTAssertEqual(firstIDs.count, 1)
        XCTAssertEqual(secondIDs, firstIDs)
        XCTAssertEqual(viewModel.queue.count, 1)
        XCTAssertEqual(viewModel.queue[0].repairTarget, damaged)
        XCTAssertEqual(viewModel.queue[0].subtitle, "Repair · Hi-Res FLAC")
    }

    private static func archiveTrack(
        relativePath: String,
        trackID: String = "track-id",
        albumID: String = "album-id",
        formatID: Int = 27,
        integrity: QobuzArchiveIntegrity = .verified
    ) -> QobuzArchiveTrack {
        QobuzArchiveTrack(
            relativePath: relativePath,
            qobuzTrackID: trackID,
            qobuzAlbumID: albumID,
            formatID: formatID,
            bitDepth: 24,
            samplingRate: 96,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: String(repeating: "a", count: 64),
            byteCount: 1_024,
            integrity: integrity
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

private struct MemoryCredentialStore: NativeCredentialStoring {
    var credentials: CredentialDraft?

    init(credentials: CredentialDraft? = nil) {
        self.credentials = credentials
    }

    func load() throws -> CredentialDraft? { credentials }
    func save(_ credentials: CredentialDraft) throws {}
}

private extension CredentialDraft {
    static let complete = CredentialDraft(appID: "app-id", appSecret: "app-secret", authToken: "token")
}

private final class FakeQobuzService: NativeQobuzServicing, @unchecked Sendable {
    func validateAccount() async throws -> String { "FR" }

    func search(_ query: String, category: QobuzSearchCategory, limit: Int) async throws -> QobuzSearchResults {
        try await Task.sleep(for: .milliseconds(30))
        switch category {
        case .albums:
            return QobuzSearchResults(albums: [
                QobuzAlbumSummary(id: .init("30"), title: "30", artist: .init(id: .init("adele"), name: "Adele")),
                QobuzAlbumSummary(id: .init("19"), title: "19", artist: .init(id: .init("adele"), name: "Adele"))
            ])
        case .artists:
            return QobuzSearchResults(artists: [.init(id: .init("adele"), name: "Adele")])
        case .tracks:
            return QobuzSearchResults(tracks: [
                QobuzTrack(id: .init("hello"), title: "Hello", performer: .init(id: .init("adele"), name: "Adele"))
            ])
        }
    }

    func track(id: QobuzID) async throws -> QobuzTrack {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func album(id: QobuzID) async throws -> QobuzAlbum {
        try await Task.sleep(for: .milliseconds(10))
        return QobuzAlbum(
            id: id,
            title: "30",
            artist: .init(id: .init("adele"), name: "Adele"),
            tracks: [QobuzTrack(id: .init("easy"), title: "Easy On Me", trackNumber: 1)]
        )
    }

    func playlist(id: QobuzID) async throws -> QobuzPlaylist {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        let adele = QobuzArtist(id: id, name: "Adele")
        let other = QobuzArtist(id: QobuzID("other"), name: "Tribute Artist")
        return QobuzArtistCatalog(
            id: id,
            name: "Adele",
            albums: [
                QobuzAlbum(id: QobuzID("official"), title: "30", artist: adele, tracksCount: 12),
                QobuzAlbum(id: QobuzID("appearance"), title: "Adele Covers", artist: other, tracksCount: 10),
                QobuzAlbum(
                    id: QobuzID("blocked"),
                    title: "Blocked",
                    artist: adele,
                    tracksCount: 1,
                    streamable: false
                )
            ]
        )
    }

    func fileInfo(trackID: QobuzID, quality: QobuzQuality) async throws -> QobuzFileInfo {
        throw NativeQobuzError.unavailable("Unused by this test")
    }
}

private final class FakeArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    let snapshot: QobuzArchiveSnapshot
    private let lock = NSLock()
    private var scans = 0

    init(snapshot: QobuzArchiveSnapshot) {
        self.snapshot = snapshot
    }

    var scanCount: Int {
        lock.withLock { scans }
    }

    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        lock.withLock { scans += 1 }
        try await Task.sleep(for: .milliseconds(10))
        return snapshot
    }
}

private final class MemoryArchiveStore: NativeArchiveIndexStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: QobuzArchiveSnapshot?

    init(snapshot: QobuzArchiveSnapshot? = nil) {
        stored = snapshot
    }

    var snapshot: QobuzArchiveSnapshot? {
        lock.withLock { stored }
    }

    func load() throws -> QobuzArchiveSnapshot? {
        lock.withLock { stored }
    }

    func save(_ snapshot: QobuzArchiveSnapshot) throws {
        lock.withLock { stored = snapshot }
    }
}

private final class MemorySessionStore: NativeSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeSessionSnapshot?

    init(snapshot: NativeSessionSnapshot? = nil) {
        stored = snapshot
    }

    var snapshot: NativeSessionSnapshot? {
        lock.withLock { stored }
    }

    func load() throws -> NativeSessionSnapshot? {
        lock.withLock { stored }
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        lock.withLock { stored = snapshot }
    }
}
