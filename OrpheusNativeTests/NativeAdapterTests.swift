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
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func playlist(id: QobuzID) async throws -> QobuzPlaylist {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func fileInfo(trackID: QobuzID, quality: QobuzQuality) async throws -> QobuzFileInfo {
        throw NativeQobuzError.unavailable("Unused by this test")
    }
}
