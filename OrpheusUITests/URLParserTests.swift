import XCTest
@testable import OrpheusUI

final class URLParserTests: XCTestCase {
    func testAlbumTrackPlaylistAndArtistURLs() {
        XCTAssertEqual(QobuzURLParser.parse("https://open.qobuz.com/album/abc123"), .album("abc123"))
        XCTAssertEqual(QobuzURLParser.parse("https://play.qobuz.com/track/52151405?utm=test"), .track("52151405"))
        XCTAssertEqual(QobuzURLParser.parse("https://www.qobuz.com/playlist/98765"), .playlist("98765"))
        XCTAssertEqual(QobuzURLParser.parse("https://open.qobuz.com/interpreter/444"), .artist("444"))
        XCTAssertEqual(
            QobuzURLParser.parse("https://www.qobuz.com/us-en/album/visitor-sienna-spiro/je3x92urb9drs"),
            .album("je3x92urb9drs")
        )
        XCTAssertEqual(
            QobuzURLParser.parse("https://www.qobuz.com/us-en/track/some-track/52151405?utm=test"),
            .track("52151405")
        )
        XCTAssertEqual(
            QobuzURLParser.parse("https://www.qobuz.com/us-en/interpreter/sienna-spiro/22407938"),
            .artist("22407938")
        )
        XCTAssertEqual(
            QobuzURLParser.parse("https://www.qobuz.com/us-en/interpreter/sienna-spiro/22407938").downloadableURL,
            "https://open.qobuz.com/artist/22407938"
        )
    }

    func testInvalidURLs() {
        XCTAssertEqual(QobuzURLParser.parse("https://example.com/album/abc123"), .invalid)
        XCTAssertEqual(QobuzURLParser.parse("https://open.qobuz.com/notmusic/abc123"), .invalid)
        XCTAssertEqual(QobuzURLParser.parse("not a url"), .invalid)
    }

    func testExtractsMultipleLinksAndReportsDuplicates() {
        let text = """
        Listen https://open.qobuz.com/album/abc123
        Duplicate https://www.qobuz.com/us-en/album/name/abc123?utm=test,
        Bad https://open.qobuz.com/notmusic/zzz
        Ignore https://example.com/album/abc123
        Artist https://www.qobuz.com/us-en/interpreter/sienna-spiro/22407938)
        """

        let result = QobuzLinkExtractor.extract(from: text)

        XCTAssertEqual(result.links.map(\.canonicalURL), [
            "https://open.qobuz.com/album/abc123",
            "https://open.qobuz.com/artist/22407938"
        ])
        XCTAssertEqual(result.invalidQobuzURLs, ["https://open.qobuz.com/notmusic/zzz"])
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.ignoredURLCount, 1)
    }

    func testExtractionIgnoresUnsupportedQobuzHosts() {
        let text = """
        API https://api.qobuz.com/album/abc123
        Bad path https://open.qobuz.com/notmusic/zzz
        """

        let result = QobuzLinkExtractor.extract(from: text)

        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.invalidQobuzURLs, ["https://open.qobuz.com/notmusic/zzz"])
        XCTAssertEqual(result.ignoredURLCount, 1)
    }

    func testArtistPreviewDecodesWithMissingOptionalFields() throws {
        let json = Data("""
        {
          "id": 22407938,
          "name": "Sienna Spiro",
          "albums": {
            "items": [
              { "id": "je3x92urb9drs", "title": "Visitor" }
            ]
          }
        }
        """.utf8)

        let artist = try JSONDecoder().decode(QobuzArtistResponse.self, from: json)
        let info = ArtistPreviewInfo(from: artist, fallbackID: "fallback")

        XCTAssertEqual(info.id, "22407938")
        XCTAssertEqual(info.name, "Sienna Spiro")
        XCTAssertEqual(info.albumCount, 1)
        XCTAssertEqual(info.downloadURL, "https://open.qobuz.com/artist/22407938")
    }

    func testAlbumDecoderKeepsTracksWhenOptionalMetadataIsMalformed() throws {
        let json = Data("""
        {
          "id": "album123",
          "title": "Album With Tracks",
          "artist": { "id": "artist123", "name": "Test Artist" },
          "description": { "html": "<p>Unexpected shape</p>" },
          "goodies": [{ "unexpected": true }],
          "tracks_count": 2,
          "tracks": {
            "total": 2,
            "items": [
              { "id": 111, "title": "First", "track_number": 1, "duration": 180 },
              { "id": 222, "track_number": 2, "duration": 200 }
            ]
          }
        }
        """.utf8)

        let album = try JSONDecoder().decode(QobuzAlbumResponse.self, from: json)

        XCTAssertEqual(album.tracks?.items.count, 2)
        XCTAssertEqual(album.tracks?.items[0].title, "First")
        XCTAssertEqual(album.tracks?.items[1].title, "Track 222")
        XCTAssertEqual(album.tracks?.total, 2)
    }

    func testSearchItemsSkipMalformedEntriesInsteadOfFailingWholeCategory() throws {
        let json = Data("""
        {
          "albums": {
            "items": [
              { "title": "Missing ID", "artist": { "name": "Broken" } },
              {
                "id": "valid-album",
                "title": "Valid Album",
                "artist": { "id": "artist-valid", "name": "Valid Artist" }
              }
            ]
          },
          "tracks": {
            "items": [
              { "id": "valid-track", "title": "Valid Track", "album": { "id": "valid-album", "title": "Valid Album" } },
              { "id": "broken-track", "title": "Missing Album" }
            ]
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(QobuzSearchResponse.self, from: json)

        XCTAssertEqual(response.albums?.items.map(\.id.value), ["valid-album"])
        XCTAssertEqual(response.tracks?.items.map(\.id.value), ["valid-track"])
    }

    @MainActor
    func testQueueAddsSelectsAndSkipsDuplicates() {
        let vm = MainViewModel()
        vm.batchInput = """
        https://open.qobuz.com/album/abc123
        https://www.qobuz.com/us-en/album/title/abc123
        https://open.qobuz.com/notmusic/zzz
        """

        vm.addLinksFromInput()

        XCTAssertEqual(vm.queuedLinks.count, 2)
        XCTAssertEqual(vm.queuedLinks.first?.canonicalURL, "https://open.qobuz.com/album/abc123")
        XCTAssertEqual(vm.selectedQueueID, vm.queuedLinks.first?.id)
        XCTAssertTrue(vm.queuedLinks[0].state.canStart)
        XCTAssertFalse(vm.queuedLinks[1].state.canStart)
    }

    @MainActor
    func testBrowseCategorySwitchingOnlyChangesSelectedCategory() {
        let vm = MainViewModel()
        vm.browseRoute = .results
        vm.browseResults = .loadingAll()

        vm.selectBrowseCategory(.tracks)

        XCTAssertEqual(vm.selectedBrowseCategory, .tracks)
        XCTAssertEqual(vm.browseRoute, .results)
        XCTAssertTrue(vm.browseResults.albums.state.isLoading)
        XCTAssertTrue(vm.browseResults.artists.state.isLoading)
        XCTAssertTrue(vm.browseResults.tracks.state.isLoading)
    }

    @MainActor
    func testBrowseSearchRequestsAllCategories() async {
        let service = FakeQobuzService()
        let vm = MainViewModel(qobuzAPI: service)
        vm.linkInput = "sienna spiro"

        vm.performSearch()
        await waitUntil { service.searchCalls.count == 3 }

        XCTAssertEqual(Set(service.searchCalls.map(\.type)), Set([.album, .artist, .track]))
        XCTAssertEqual(Set(service.searchCalls.map(\.limit)), [30])
        XCTAssertEqual(vm.browseRoute, .results)
    }

    @MainActor
    func testBrowseSearchKeepsPartialFailuresScopedToOneCategory() async {
        let service = FakeQobuzService { query, type, _ in
            if type == .artist {
                throw FakeQobuzError.plannedFailure
            }
            return searchResponse(query: query, type: type)
        }
        let vm = MainViewModel(qobuzAPI: service)
        vm.linkInput = "visitor"

        vm.performSearch()
        await waitUntil { service.searchCalls.count == 3 }
        await waitUntil {
            vm.browseResults.albums.count == 1
                && vm.browseResults.tracks.count == 1
                && vm.browseResults.artists.state.errorMessage != nil
        }

        XCTAssertEqual(vm.browseResults.albums.count, 1)
        XCTAssertEqual(vm.browseResults.tracks.count, 1)
        XCTAssertEqual(vm.browseResults.artists.state.errorMessage, FakeQobuzError.plannedFailure.localizedDescription)
    }

    @MainActor
    func testBrowseSearchIgnoresStaleResponses() async {
        let service = FakeQobuzService { query, type, _ in
            if query == "old" {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            return searchResponse(query: query, type: type)
        }
        let vm = MainViewModel(qobuzAPI: service)

        vm.linkInput = "old"
        vm.performSearch()
        vm.linkInput = "new"
        vm.performSearch()

        await waitUntil {
            vm.browseResults.albums.albums.first?.title == "new album"
                && vm.browseResults.artists.artists.first?.name == "new artist"
                && vm.browseResults.tracks.tracks.first?.title == "new track"
        }

        XCTAssertEqual(vm.browseQuery, "new")
        XCTAssertEqual(vm.browseResults.albums.albums.first?.title, "new album")
        XCTAssertEqual(vm.browseResults.artists.artists.first?.name, "new artist")
        XCTAssertEqual(vm.browseResults.tracks.tracks.first?.title, "new track")
    }

    @MainActor
    func testBrowseSearchAutoSelectsFirstCategoryWithResults() async {
        let service = FakeQobuzService { _, type, _ in
            switch type {
            case .album:
                return QobuzSearchResponse(albums: QobuzSearchItems(items: []), tracks: nil, artists: nil)
            case .artist:
                return QobuzSearchResponse(albums: nil, tracks: nil, artists: QobuzSearchItems(items: []))
            case .track:
                return QobuzSearchResponse(
                    albums: nil,
                    tracks: QobuzSearchItems(items: [
                        try decodeQobuzTrack(id: "track-result", title: "Track Result")
                    ]),
                    artists: nil
                )
            case .playlist:
                return QobuzSearchResponse(albums: nil, tracks: nil, artists: nil)
            }
        }
        let vm = MainViewModel(qobuzAPI: service)
        vm.linkInput = "track only"

        vm.performSearch()
        await waitUntil { vm.browseResults.tracks.count == 1 }

        XCTAssertEqual(vm.selectedBrowseCategory, .tracks)
    }

    @MainActor
    func testBrowseSearchDoesNotAutoSelectAfterManualCategoryChoice() async {
        let service = FakeQobuzService { _, type, _ in
            switch type {
            case .album:
                try? await Task.sleep(nanoseconds: 30_000_000)
                return QobuzSearchResponse(albums: QobuzSearchItems(items: []), tracks: nil, artists: nil)
            case .artist:
                return QobuzSearchResponse(albums: nil, tracks: nil, artists: QobuzSearchItems(items: []))
            case .track:
                return QobuzSearchResponse(
                    albums: nil,
                    tracks: QobuzSearchItems(items: [
                        try decodeQobuzTrack(id: "track-result", title: "Track Result")
                    ]),
                    artists: nil
                )
            case .playlist:
                return QobuzSearchResponse(albums: nil, tracks: nil, artists: nil)
            }
        }
        let vm = MainViewModel(qobuzAPI: service)
        vm.linkInput = "track only"

        vm.performSearch()
        vm.selectBrowseCategory(.albums)
        await waitUntil { vm.browseResults.tracks.count == 1 }

        XCTAssertEqual(vm.selectedBrowseCategory, .albums)
    }

    @MainActor
    func testBrowseSearchFiltersUnavailableAlbumsForAccountRegion() async {
        let service = FakeQobuzService { _, type, _ in
            if type == .album {
                return QobuzSearchResponse(
                    albums: QobuzSearchItems(items: [
                        try decodeQobuzAlbum(
                            id: "0634904431365",
                            title: "19",
                            displayable: false,
                            streamable: false
                        ),
                        try decodeQobuzAlbum(
                            id: "0634904031367",
                            title: "19",
                            displayable: true,
                            streamable: true
                        )
                    ]),
                    tracks: nil,
                    artists: nil
                )
            }
            return searchResponse(query: "adele 19", type: type)
        }
        let vm = MainViewModel(qobuzAPI: service)
        vm.linkInput = "adele 19"

        vm.performSearch()
        await waitUntil { vm.browseResults.albums.state == .loaded }

        XCTAssertEqual(vm.browseResults.albums.albums.map(\.id.value), ["0634904031367"])
        XCTAssertEqual(vm.browseResults.albums.unavailableCount, 1)
    }

    @MainActor
    func testBrowseSearchResolvesUnavailableAlbumFromPlayableTrackResult() async {
        let service = FakeQobuzService(
            searchHandler: { _, type, _ in
                switch type {
                case .album:
                    return QobuzSearchResponse(
                        albums: QobuzSearchItems(items: [
                            try decodeQobuzAlbum(
                                id: "0634904431365",
                                title: "19",
                                artistName: "Adele",
                                displayable: false,
                                streamable: false,
                                downloadable: false
                            )
                        ]),
                        tracks: nil,
                        artists: nil
                    )
                case .track:
                    return QobuzSearchResponse(
                        albums: nil,
                        tracks: QobuzSearchItems(items: [
                            try decodeQobuzTrack(
                                id: "2531961",
                                title: "Make You Feel My Love",
                                albumID: "0634904031367",
                                albumTitle: "19",
                                artistName: "Adele",
                                displayable: true,
                                streamable: true,
                                downloadable: true
                            )
                        ]),
                        artists: nil
                    )
                case .artist, .playlist:
                    return searchResponse(query: "adele 19", type: type)
                }
            },
            albumHandler: { id in
                try decodeQobuzAlbum(
                    id: id,
                    title: "19",
                    artistName: "Adele",
                    tracks: ["Daydreamer"],
                    displayable: true,
                    streamable: true,
                    downloadable: true
                )
            }
        )
        let vm = MainViewModel(qobuzAPI: service)
        vm.linkInput = "adele 19"

        vm.performSearch()
        await waitUntil { vm.browseResults.albums.state == .loaded }

        XCTAssertEqual(vm.browseResults.albums.albums.map(\.id.value), ["0634904031367"])
        XCTAssertEqual(vm.browseResults.albums.unavailableCount, 0)
    }

    @MainActor
    func testBrowseActionsQueueCanonicalURLs() {
        let vm = MainViewModel()

        vm.addAlbumToQueue("album123")
        vm.addTrackToQueue("track456")
        vm.addArtistToQueue("artist789")

        XCTAssertEqual(vm.queuedLinks.map(\.canonicalURL), [
            "https://open.qobuz.com/album/album123",
            "https://open.qobuz.com/track/track456",
            "https://open.qobuz.com/artist/artist789"
        ])
    }

    @MainActor
    func testOpeningBrowseAlbumFetchesFullAlbumTracks() async throws {
        let searchAlbum = try decodeQobuzAlbum(id: "album123", title: "Search Album")
        let service = FakeQobuzService(albumHandler: { id in
            try decodeQobuzAlbum(
                id: id,
                title: "Full Album",
                tracks: ["First Track", "Second Track"]
            )
        })
        let vm = MainViewModel(qobuzAPI: service)
        vm.browseRoute = .results

        vm.pushAlbum(searchAlbum)

        await waitUntil {
            if case .albumDetail(_, let tracks) = vm.browseRoute {
                return tracks.map(\.title) == ["First Track", "Second Track"]
            }
            return false
        }

        guard case .albumDetail(let album, let tracks) = vm.browseRoute else {
            return XCTFail("Expected album detail route")
        }
        XCTAssertEqual(album.title, "Full Album")
        XCTAssertEqual(tracks.count, 2)
    }

    @MainActor
    func testUnavailableBrowseAlbumDoesNotQueueOrOpenDetail() throws {
        let album = try decodeQobuzAlbum(
            id: "0634904431365",
            title: "19",
            displayable: false,
            streamable: false
        )
        let vm = MainViewModel(qobuzAPI: FakeQobuzService())
        vm.browseRoute = .results

        vm.pushAlbum(album)

        guard case .error(let message) = vm.browseRoute else {
            return XCTFail("Expected unavailable album error")
        }
        XCTAssertTrue(message.contains("not available"))
        XCTAssertTrue(vm.queuedLinks.isEmpty)
    }

    @MainActor
    func testDownloadPreflightStopsBeforeQueueingWhenCredentialsAreMissing() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vm = MainViewModel(runtime: RuntimeLocator(
            applicationSupportRoot: temp.appendingPathComponent("support", isDirectory: true),
            defaultDownloadURL: temp.appendingPathComponent("downloads", isDirectory: true)
        ))
        let item = readyAlbumQueueItem()
        vm.settings = settingsDocument(appID: "", appSecret: "secret", authToken: "token", downloadPath: temp.path)
        vm.queuedLinks = [item]
        vm.selectedQueueID = item.id

        vm.downloadSelected()

        XCTAssertTrue(vm.queueNotice?.contains("missing Qobuz app ID") == true)
        XCTAssertTrue(vm.downloads.isEmpty)
        XCTAssertEqual(vm.queuedLinks.first?.state, .ready)
    }

    @MainActor
    func testDownloadPreflightStopsBeforeQueueingWhenRuntimeIsMissing() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vm = MainViewModel(runtime: RuntimeLocator(
            applicationSupportRoot: temp.appendingPathComponent("support", isDirectory: true),
            defaultDownloadURL: temp.appendingPathComponent("downloads", isDirectory: true)
        ))
        let item = readyAlbumQueueItem()
        vm.settings = settingsDocument(appID: "app", appSecret: "secret", authToken: "token", downloadPath: temp.path)
        vm.queuedLinks = [item]
        vm.selectedQueueID = item.id

        vm.downloadSelected()

        XCTAssertTrue(vm.queueNotice?.contains("runtime folder is missing") == true)
        XCTAssertTrue(vm.downloads.isEmpty)
        XCTAssertEqual(vm.queuedLinks.first?.state, .ready)
    }

    @MainActor
    func testCancelAllCancelsPreflightAndLeavesQueueReady() async throws {
        let temp = try makeTempDirectory()
        let runtime = try preparedRuntime(temp: temp)
        let service = FakeQobuzService(albumHandler: { id in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try decodeQobuzAlbum(id: id, title: "Slow Album", tracks: ["One"])
        })
        let vm = MainViewModel(runtime: runtime, qobuzAPI: service)
        let item = readyAlbumQueueItem()
        vm.settings = settingsDocument(
            appID: "app",
            appSecret: "secret",
            authToken: "token",
            downloadPath: temp.appendingPathComponent("downloads", isDirectory: true).path
        )
        vm.queuedLinks = [item]
        vm.selectedQueueID = item.id

        vm.downloadSelected()
        await waitUntil { vm.isPreflighting }
        vm.cancelAllDownloads()
        await waitUntil { !vm.isPreflighting }

        XCTAssertEqual(vm.queueNotice, "Download preflight cancelled.")
        XCTAssertTrue(vm.downloads.isEmpty)
        XCTAssertEqual(vm.queuedLinks.first?.state, .ready)
    }

    @MainActor
    func testSettingsCannotChangeDuringPreflight() async throws {
        let temp = try makeTempDirectory()
        let runtime = try preparedRuntime(temp: temp)
        let service = FakeQobuzService(albumHandler: { id in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try decodeQobuzAlbum(id: id, title: "Slow Album", tracks: ["One"])
        })
        let vm = MainViewModel(runtime: runtime, qobuzAPI: service)
        let item = readyAlbumQueueItem()
        vm.settings = settingsDocument(
            appID: "app",
            appSecret: "secret",
            authToken: "token",
            downloadPath: temp.appendingPathComponent("downloads", isDirectory: true).path
        )
        vm.queuedLinks = [item]
        vm.selectedQueueID = item.id

        vm.downloadSelected()
        await waitUntil { vm.isPreflighting }
        vm.applySettings(
            appID: "new-app",
            appSecret: "new-secret",
            authToken: "new-token",
            userID: "new-user",
            downloadPath: temp.path,
            quality: "lossless"
        )

        XCTAssertEqual(vm.settings?.qobuzAppID, "app")
        XCTAssertTrue(vm.queueNotice?.contains("Wait for the current download check") == true)
        vm.cancelAllDownloads()
    }

    @MainActor
    func testRevealInFinderUsesResolvedOutputURLWhenAvailable() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let finder = FakeFinderRevealer()
        let runtime = RuntimeLocator(defaultDownloadURL: temp)
        let vm = MainViewModel(runtime: runtime, finderRevealer: finder)
        let id = UUID()
        let target = temp.appendingPathComponent("Resolved Album", isDirectory: true)
        vm.settings = settingsDocument(appID: "app", appSecret: "secret", authToken: "token", downloadPath: temp.path)
        vm.downloads = [
            DownloadItem(
                id: id,
                queueID: nil,
                url: "https://open.qobuz.com/album/abc123",
                title: "Resolved Album",
                status: .completed,
                progressUnit: .tracks,
                resolvedOutputURL: target
            )
        ]

        vm.revealInFinder(id: id)

        XCTAssertEqual(finder.revealedURLs, [target])
    }

    @MainActor
    func testRevealInFinderFallsBackToDownloadRoot() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let finder = FakeFinderRevealer()
        let runtime = RuntimeLocator(defaultDownloadURL: temp)
        let vm = MainViewModel(runtime: runtime, finderRevealer: finder)
        let id = UUID()
        vm.settings = settingsDocument(appID: "app", appSecret: "secret", authToken: "token", downloadPath: temp.path)
        vm.downloads = [
            DownloadItem(
                id: id,
                queueID: nil,
                url: "https://open.qobuz.com/album/abc123",
                title: "Album",
                status: .completed,
                progressUnit: .tracks
            )
        ]

        vm.revealInFinder(id: id)

        XCTAssertEqual(finder.revealedURLs, [temp])
    }

    func testDownloadOutputResolverPrefersDirectChildCreatedAfterStart() throws {
        let temp = try makeTempDirectory()
        let old = temp.appendingPathComponent("Old Album", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let startedAt = Date()
        let album = temp.appendingPathComponent("New Album", isDirectory: true)
        let nested = album.appendingPathComponent("track.flac")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: nested)
        let newDate = startedAt.addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: album.path)
        try FileManager.default.setAttributes([.modificationDate: newDate.addingTimeInterval(1)], ofItemAtPath: nested.path)

        let resolved = DownloadOutputResolver(fileManager: .default).resolveOutput(in: temp, startedAt: startedAt)

        XCTAssertEqual(resolved?.standardizedFileURL.path, album.standardizedFileURL.path)
    }

    private func readyAlbumQueueItem() -> QueuedLink {
        QueuedLink(
            originalURL: "https://open.qobuz.com/album/abc123",
            canonicalURL: "https://open.qobuz.com/album/abc123",
            parsed: .album("abc123"),
            title: nil,
            subtitle: "https://open.qobuz.com/album/abc123",
            coverURL: nil,
            state: .ready,
            cachedPreview: nil,
            downloadID: nil
        )
    }

    private func settingsDocument(
        appID: String,
        appSecret: String,
        authToken: String,
        downloadPath: String
    ) -> SettingsDocument {
        SettingsDocument(root: [
            "global": .object([
                "general": .object([
                    "download_path": .string(downloadPath),
                    "download_quality": .string("hifi")
                ])
            ]),
            "modules": .object([
                "qobuz": .object([
                    "app_id": .string(appID),
                    "app_secret": .string(appSecret),
                    "auth_token": .string(authToken),
                    "user_id": .string("")
                ])
            ])
        ])
    }

    private func makeTempDirectory() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func preparedRuntime(temp: URL) throws -> RuntimeLocator {
        let support = temp.appendingPathComponent("support", isDirectory: true)
        let runtimeProject = support.appendingPathComponent("OrpheusDL", isDirectory: true)
        let config = runtimeProject.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let helper = temp.appendingPathComponent("orpheus-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        return RuntimeLocator(
            applicationSupportRoot: support,
            defaultDownloadURL: temp.appendingPathComponent("downloads", isDirectory: true),
            helperURL: helper
        )
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakeFinderRevealer: FinderRevealing {
    private(set) var revealedURLs: [URL] = []

    func reveal(urls: [URL]) {
        revealedURLs = urls
    }
}

private enum FakeQobuzError: LocalizedError {
    case plannedFailure

    var errorDescription: String? {
        "Planned Qobuz failure"
    }
}

private final class FakeQobuzService: QobuzServicing {
    struct SearchCall: Equatable {
        let query: String
        let type: SearchType
        let limit: Int
    }

    typealias SearchHandler = (String, SearchType, Int) async throws -> QobuzSearchResponse

    private let lock = NSLock()
    private var storedSearchCalls: [SearchCall] = []
    private let searchHandler: SearchHandler

    typealias AlbumHandler = (String) async throws -> QobuzAlbumResponse

    private let albumHandler: AlbumHandler

    typealias FileURLHandler = (String, String) async throws -> QobuzFileURLResponse

    private let fileURLHandler: FileURLHandler

    init(
        searchHandler: @escaping SearchHandler = { query, type, _ in
            searchResponse(query: query, type: type)
        },
        albumHandler: @escaping AlbumHandler = { id in
            try decodeQobuzAlbum(id: id, title: "\(id) album")
        },
        fileURLHandler: @escaping FileURLHandler = { trackID, quality in
            QobuzFileURLResponse(
                url: "https://example.com/\(trackID)-\(quality).flac",
                formatID: QobuzDownloadQuality.formatID(for: quality),
                bitDepth: 24,
                samplingRate: 96
            )
        }
    ) {
        self.searchHandler = searchHandler
        self.albumHandler = albumHandler
        self.fileURLHandler = fileURLHandler
    }

    var searchCalls: [SearchCall] {
        lock.lock()
        defer { lock.unlock() }
        return storedSearchCalls
    }

    func validateAccount() async throws -> String {
        "US"
    }

    func region() async throws -> String {
        "US"
    }

    func getAlbum(id: String) async throws -> QobuzAlbumResponse {
        try await albumHandler(id)
    }

    func getTrack(id: String) async throws -> QobuzTrackResponse {
        try decodeQobuzTrack(id: id, title: "\(id) track")
    }

    func getArtist(id: String) async throws -> QobuzArtistResponse {
        try decodeQobuzArtist(id: id, name: "\(id) artist")
    }

    func getPlaylist(id: String) async throws -> QobuzPlaylistResponse {
        QobuzPlaylistResponse(
            id: FlexibleID(id),
            name: "\(id) playlist",
            title: nil,
            tracks: QobuzTracksContainer(items: [
                QobuzTrackRef(id: FlexibleID("\(id)-track"), title: "Playlist Track")
            ])
        )
    }

    func getFileURL(trackID: String, quality: String) async throws -> QobuzFileURLResponse {
        try await fileURLHandler(trackID, quality)
    }

    func search(query: String, type: SearchType, limit: Int) async throws -> QobuzSearchResponse {
        lock.lock()
        storedSearchCalls.append(SearchCall(query: query, type: type, limit: limit))
        lock.unlock()
        return try await searchHandler(query, type, limit)
    }
}

private func searchResponse(query: String, type: SearchType) -> QobuzSearchResponse {
    switch type {
    case .album:
        return QobuzSearchResponse(
            albums: QobuzSearchItems(items: [try! decodeQobuzAlbum(id: "\(query)-album", title: "\(query) album")]),
            tracks: nil,
            artists: nil
        )
    case .artist:
        return QobuzSearchResponse(
            albums: nil,
            tracks: nil,
            artists: QobuzSearchItems(items: [
                QobuzSearchArtist(id: FlexibleID("\(query)-artist"), name: "\(query) artist", image: nil)
            ])
        )
    case .track:
        return QobuzSearchResponse(
            albums: nil,
            tracks: QobuzSearchItems(items: [try! decodeQobuzTrack(id: "\(query)-track", title: "\(query) track")]),
            artists: nil
        )
    case .playlist:
        return QobuzSearchResponse(albums: nil, tracks: nil, artists: nil)
    }
}

private func decodeQobuzAlbum(
    id: String,
    title: String,
    artistName: String = "Test Artist",
    tracks: [String] = [],
    displayable: Bool? = nil,
    streamable: Bool? = nil,
    downloadable: Bool? = nil
) throws -> QobuzAlbumResponse {
    let trackItems = tracks.enumerated().map { index, title in
        """
              {
                "id": "\(id)-track-\(index + 1)",
                "title": "\(title)",
                "track_number": \(index + 1),
                "duration": 180
              }
        """
    }.joined(separator: ",\n")
    let tracksJSON = tracks.isEmpty ? "" : """
      ,
      "tracks": {
        "total": \(tracks.count),
        "items": [
    \(trackItems)
        ]
      }
    """
    let availabilityJSON = [
        displayable.map { "\"displayable\": \($0)" },
        streamable.map { "\"streamable\": \($0)" },
        downloadable.map { "\"downloadable\": \($0)" }
    ]
        .compactMap { $0 }
        .joined(separator: ",\n      ")
    let availabilityPrefix = availabilityJSON.isEmpty ? "" : "\n      \(availabilityJSON),"

    return try JSONDecoder().decode(QobuzAlbumResponse.self, from: Data("""
    {
      "id": "\(id)",
      "title": "\(title)",
      "artist": { "id": "artist-\(id)", "name": "\(artistName)" },
      \(availabilityPrefix)
      "tracks_count": 1,
      "maximum_bit_depth": 24,
      "maximum_sampling_rate": 96,
      "hires_streamable": true
      \(tracksJSON)
    }
    """.utf8))
}

private func decodeQobuzTrack(
    id: String,
    title: String,
    albumID: String? = nil,
    albumTitle: String = "Test Album",
    artistName: String = "Test Artist",
    displayable: Bool? = nil,
    streamable: Bool? = nil,
    downloadable: Bool? = nil
) throws -> QobuzTrackResponse {
    let availabilityJSON = [
        displayable.map { "\"displayable\": \($0)" },
        streamable.map { "\"streamable\": \($0)" },
        downloadable.map { "\"downloadable\": \($0)" }
    ]
        .compactMap { $0 }
        .joined(separator: ",\n      ")
    let availabilityPrefix = availabilityJSON.isEmpty ? "" : "\n      \(availabilityJSON),"
    let resolvedAlbumID = albumID ?? "album-\(id)"

    return try JSONDecoder().decode(QobuzTrackResponse.self, from: Data("""
    {
      "id": "\(id)",
      "title": "\(title)",
      \(availabilityPrefix)
      "duration": 180,
      "album": {
        "id": "\(resolvedAlbumID)",
        "title": "\(albumTitle)",
        "artist": { "id": "artist-\(id)", "name": "\(artistName)" }
      },
      "performer": { "id": "artist-\(id)", "name": "\(artistName)" }
    }
    """.utf8))
}

private func decodeQobuzArtist(id: String, name: String) throws -> QobuzArtistResponse {
    try JSONDecoder().decode(QobuzArtistResponse.self, from: Data("""
    {
      "id": "\(id)",
      "name": "\(name)",
      "albums": { "items": [] }
    }
    """.utf8))
}
