import XCTest
import NativeQobuzCore
@testable import OrpheusNative

@MainActor
final class NativeAdapterTests: XCTestCase {
    func testConnectivityRecoveryRetriesOnceThenWaitsForARealPathChange() {
        var policy = NativeConnectivityRecoveryPolicy()

        XCTAssertEqual(policy.action(state: .online, generation: 4), .retryNow)
        XCTAssertEqual(
            policy.action(state: .online, generation: 4),
            .waitForChange(afterGeneration: 4)
        )
        policy.recovered()
        XCTAssertEqual(policy.action(state: .online, generation: 6), .retryNow)

        var offlinePolicy = NativeConnectivityRecoveryPolicy()
        XCTAssertEqual(
            offlinePolicy.action(state: .offline, generation: 9),
            .waitForChange(afterGeneration: 9)
        )
    }

    func testConnectivityMonitorLifecycleUpdatesViewModelAndStopsAtTermination() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let monitor = FakeConnectivityMonitor()
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            connectivityMonitor: monitor,
            powerActivityManager: FakePowerActivityManager()
        )

        viewModel.start()
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(viewModel.connectivityState, .unknown)

        monitor.emit(.offline)
        XCTAssertEqual(viewModel.connectivityState, .offline)
        monitor.emit(.online)
        XCTAssertEqual(viewModel.connectivityState, .online)

        viewModel.prepareForTermination()
        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testPowerActivityAlwaysEndsWhenTransferWorkThrows() async {
        struct FixtureFailure: Error {}
        let manager = FakePowerActivityManager()

        do {
            try await withNativePowerActivity(using: manager, reason: "Fixture transfer") {
                throw FixtureFailure()
            }
            XCTFail("Expected fixture failure")
        } catch is FixtureFailure {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(manager.beginReasons, ["Fixture transfer"])
        XCTAssertEqual(manager.endCount, 1)
    }

    func testWaitingForNetworkStatusesRoundTripThroughSessionCoding() throws {
        let item = NativeQueueItem(request: .album(QobuzID("album")))
        var activity = NativeDownloadActivity(id: UUID(), queueID: item.id, title: "Album")
        activity.phase = "Waiting for network · partial file preserved"
        let value = NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            operations: [NativeDownloadOperation(
                queueID: item.id,
                activityID: activity.id,
                status: .waitingForNetwork
            )],
            selectedQueueID: item.id,
            linkInbox: []
        )

        let decoded = try JSONDecoder().decode(
            NativeSessionSnapshot.self,
            from: JSONEncoder().encode(value)
        )

        XCTAssertEqual(decoded.operations.first?.status, .waitingForNetwork)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        let queue = try XCTUnwrap((object["queue"] as? [[String: Any]])?.first)
        let activities = try XCTUnwrap((object["activities"] as? [[String: Any]])?.first)
        XCTAssertNil(queue["status"])
        XCTAssertNil(activities["status"])
    }

    func testBrowseResultsOwnEveryCategoryWithoutCrossCategoryMutation() {
        var results = NativeBrowseResults()
        results.replace(
            QobuzSearchResults(artists: [.init(id: .init("artist"), name: "Artist")]),
            for: .artists
        )
        results.replace(
            QobuzSearchResults(playlists: [.init(id: .init("playlist"), name: "Playlist", tracks: [])]),
            for: .playlists
        )

        XCTAssertEqual(results.count(for: .albums), 0)
        XCTAssertEqual(results.count(for: .artists), 1)
        XCTAssertEqual(results.count(for: .playlists), 1)
        XCTAssertEqual(results.count(for: .tracks), 0)
        XCTAssertEqual(results.totalCount, 2)
        XCTAssertEqual(results.firstNonemptyCategory, .artists)
    }

    func testBrowseResultsAppendPagesWithoutDuplicatingOverlappingItems() {
        var results = NativeBrowseResults()
        results.replace(
            QobuzSearchResults(
                tracks: [
                    QobuzTrack(id: .init("one"), title: "One"),
                    QobuzTrack(id: .init("two"), title: "Two")
                ],
                nextOffset: 2,
                total: 3
            ),
            for: .tracks
        )
        results.append(
            QobuzSearchResults(
                tracks: [
                    QobuzTrack(id: .init("two"), title: "Two"),
                    QobuzTrack(id: .init("three"), title: "Three")
                ],
                offset: 2,
                total: 3
            ),
            for: .tracks
        )

        XCTAssertEqual(results.tracks.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(results.total(for: .tracks), 3)
        XCTAssertNil(results.nextOffset(for: .tracks))
    }

    func testLibraryProblemsExplainIntegrityAndSeparateManualIndexIssues() throws {
        let tracks = [
            Self.archiveTrack(relativePath: "Album/01.flac", trackID: "missing", integrity: .missing),
            Self.archiveTrack(relativePath: "Album/02.flac", trackID: "changed", integrity: .checksumMismatch),
            Self.archiveTrack(
                relativePath: "Album/03.flac",
                trackID: "conflict",
                formatID: 999,
                integrity: .metadataConflict
            ),
            Self.archiveTrack(relativePath: "Album/04.flac", trackID: "unreadable", integrity: .unreadable),
            Self.archiveTrack(relativePath: "Album/05.flac", trackID: "verified")
        ]
        let snapshot = QobuzArchiveSnapshot(
            rootPath: "/tmp/library",
            tracks: tracks,
            issues: [
                QobuzArchiveIssue(relativePath: "Album/04.flac", message: "Permission denied"),
                QobuzArchiveIssue(relativePath: ".orpheus-library.json", message: "Malformed collection record")
            ]
        )

        let problems = Dictionary(uniqueKeysWithValues: snapshot.nativeFileProblems.map {
            ($0.track.qobuzTrackID, $0)
        })

        XCTAssertEqual(snapshot.problemCount, 5)
        XCTAssertEqual(problems["missing"]?.reasonTitle, "Missing")
        XCTAssertEqual(problems["changed"]?.reasonTitle, "Changed")
        XCTAssertEqual(problems["conflict"]?.reasonTitle, "Conflict")
        XCTAssertEqual(problems["unreadable"]?.reasonTitle, "Unreadable")
        XCTAssertEqual(problems["unreadable"]?.reasonDetail, "Permission denied")
        XCTAssertEqual(problems["missing"]?.isAutomaticallyRepairable, true)
        XCTAssertEqual(problems["changed"]?.isAutomaticallyRepairable, true)
        XCTAssertEqual(problems["conflict"]?.isAutomaticallyRepairable, false)
        XCTAssertTrue(problems["conflict"]?.repairabilityDetail.contains("999") == true)
        XCTAssertEqual(snapshot.nativeIndexProblems.count, 1)
        XCTAssertEqual(snapshot.nativeIndexProblems[0].relativePath, ".orpheus-library.json")
        XCTAssertEqual(snapshot.nativeIndexProblems[0].message, "Malformed collection record")
    }

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

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.credentialsURL)) as? [String: String]
        )
        XCTAssertEqual(Set(object.keys), Set(["appID", "appSecret", "authToken"]))
        XCTAssertEqual(object["appID"], "app-id")
        XCTAssertNil(object["userID"])
        XCTAssertNil(object["user_id"])

        let updated = CredentialDraft(
            appID: "updated-app-id",
            appSecret: "updated-secret",
            authToken: "updated-token"
        )
        try store.save(updated)
        XCTAssertEqual(try store.load(), updated)
        XCTAssertEqual(try permissions(at: paths.credentialsURL), 0o600)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: paths.applicationSupportRoot.path)),
            [paths.credentialsURL.lastPathComponent]
        )
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
        item.downloadQuality = .hiRes
        item.downloadRootPath = paths.defaultDownloadRoot.path
        item.trackPlan = [
            NativeQueueTrack(
                id: "one#0",
                qobuzID: QobuzID("one"),
                title: "One",
                subtitle: "Artist",
                duration: 180,
                position: 1,
                unavailableReason: nil
            ),
            NativeQueueTrack(
                id: "two#1",
                qobuzID: QobuzID("two"),
                title: "Two",
                subtitle: "Artist",
                duration: 200,
                position: 2,
                unavailableReason: nil
            )
        ]
        item.expectedTrackIDs = [QobuzID("one"), QobuzID("two")]
        item.selectedTrackIDs = [QobuzID("two")]
        var activity = NativeDownloadActivity(id: UUID(), queueID: item.id, title: item.title)
        activity.phase = "Paused after interruption"
        activity.progress = 0.42
        activity.bytesWritten = 42
        activity.totalBytes = 100
        activity.warnings = ["Cover artwork could not be saved."]
        activity.errorMessage = "The transfer was interrupted."
        var inboxItem = NativeLinkInboxItem(link: ParsedQobuzLink(
            original: "https://open.qobuz.com/album/album",
            request: .album(QobuzID("album"))
        ))
        inboxItem.title = "Album"
        inboxItem.status = .available
        let snapshot = NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            operations: [NativeDownloadOperation(
                queueID: item.id,
                activityID: activity.id,
                status: .paused
            )],
            selectedQueueID: item.id,
            linkInbox: [inboxItem]
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try store.load()?.linkInbox.first?.status, .available)
        XCTAssertEqual(try store.load()?.queue.first?.selectedTrackIDs, [QobuzID("two")])
        XCTAssertEqual(try store.load()?.queue.first?.trackPlan?.count, 2)
        XCTAssertTrue(paths.sessionURL.path.hasPrefix(paths.applicationSupportRoot.path))
    }

    func testQueuePlanControlsUpdateSelectionQualityOrderAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        var first = NativeQueueItem(request: .album(QobuzID("album-one")), title: "First")
        first.trackPlan = [
            NativeQueueTrack(
                id: "one#0",
                qobuzID: QobuzID("one"),
                title: "One",
                subtitle: "Artist",
                duration: 180,
                position: 1,
                unavailableReason: nil
            ),
            NativeQueueTrack(
                id: "two#1",
                qobuzID: QobuzID("two"),
                title: "Two",
                subtitle: "Artist",
                duration: 200,
                position: 2,
                unavailableReason: nil
            )
        ]
        first.expectedTrackIDs = [QobuzID("one"), QobuzID("two")]
        let second = NativeQueueItem(request: .album(QobuzID("album-two")), title: "Second")
        let sessionStore = MemorySessionStore(snapshot: NativeSessionSnapshot(
            queue: [first, second],
            activities: [],
            operations: [
                NativeDownloadOperation(queueID: first.id, status: .completed),
                NativeDownloadOperation(queueID: second.id)
            ],
            selectedQueueID: first.id,
            linkInbox: []
        ))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            archiveStore: MemoryArchiveStore(),
            sessionStore: sessionStore
        )
        viewModel.start()

        viewModel.toggleQueueTrack(QobuzID("one"), in: first.id)
        XCTAssertEqual(viewModel.queue.first?.selectedTrackIDs, [QobuzID("two")])
        XCTAssertEqual(viewModel.queuePreflight(for: try XCTUnwrap(viewModel.queue.first)).selected, 1)
        viewModel.clearQueueTrackSelection(in: first.id)
        XCTAssertFalse(try XCTUnwrap(viewModel.queue.first).hasSelectedTracks)
        viewModel.selectAllQueueTracks(in: first.id)
        viewModel.setQueueQuality(.lossless, for: first.id)
        XCTAssertNil(viewModel.queue.first?.selectedTrackIDs)
        XCTAssertEqual(viewModel.queue.first?.downloadQuality, .lossless)
        XCTAssertEqual(viewModel.status(for: try XCTUnwrap(viewModel.queue.first)), .ready)

        viewModel.moveQueueItem(second.id, before: first.id)
        XCTAssertEqual(viewModel.queue.map(\.id), [second.id, first.id])
        viewModel.moveQueueItemDown(second.id)
        XCTAssertEqual(viewModel.queue.map(\.id), [first.id, second.id])
        viewModel.prepareForTermination()
        XCTAssertEqual(sessionStore.snapshot?.queue.map(\.id), [first.id, second.id])
        XCTAssertEqual(sessionStore.snapshot?.queue.first?.downloadQuality, .lossless)
        XCTAssertNil(sessionStore.snapshot?.queue.first?.selectedTrackIDs)
    }

    func testActivityFindsOnlyRecoverableNonemptyPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let output = paths.defaultDownloadRoot
            .appendingPathComponent("Artist/Album/01. Track.flac")
        let partial = QobuzDownloadArtifacts.partialURL(
            for: output,
            formatID: QobuzQuality.hiRes.maximumFormat.formatID
        )
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 4_096).write(to: partial)

        let item = NativeQueueItem(request: .album(QobuzID("album")), title: "Album")
        var activity = NativeDownloadActivity(id: UUID(), queueID: item.id, title: "Album")
        activity.quality = .hiRes
        activity.outputURL = output
        let sessionStore = MemorySessionStore(snapshot: NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            operations: [NativeDownloadOperation(
                queueID: item.id,
                activityID: activity.id,
                status: .paused
            )],
            selectedQueueID: item.id,
            linkInbox: []
        ))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            sessionStore: sessionStore
        )
        viewModel.start()

        XCTAssertEqual(
            viewModel.resumablePartial(for: activity),
            NativePartialDownload(url: partial, bytes: 4_096)
        )

        let format7Partial = QobuzDownloadArtifacts.partialURL(
            for: output,
            formatID: QobuzAudioFormat.hiRes96.formatID
        )
        try Data(repeating: 7, count: 2_048).write(to: format7Partial)
        activity.audioFormat = .hiRes96
        XCTAssertEqual(
            viewModel.resumablePartial(for: activity),
            NativePartialDownload(url: format7Partial, bytes: 2_048)
        )

        let completedViewModel = restoredViewModel(
            status: .completed,
            item: item,
            activity: activity,
            paths: paths
        )
        XCTAssertNil(completedViewModel.resumablePartial(for: activity))

        let failedViewModel = restoredViewModel(
            status: .failed("Network unavailable"),
            item: item,
            activity: activity,
            paths: paths
        )
        XCTAssertEqual(failedViewModel.resumablePartial(for: activity)?.bytes, 2_048)

        try Data().write(to: format7Partial)
        XCTAssertNil(failedViewModel.resumablePartial(for: activity))
    }

    func testSessionCodingRejectsAnyPreviousSchema() throws {
        let data = Data(
            #"{"version":1,"queue":[],"activities":[],"selectedQueueID":null}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(NativeSessionSnapshot.self, from: data))
    }

    func testViewModelRestoresInterruptedDownloadAsPaused() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        var item = NativeQueueItem(request: .album(QobuzID("album")), title: "Interrupted Album")
        item.downloadQuality = .lossless
        item.downloadRootPath = paths.defaultDownloadRoot.path
        var activity = NativeDownloadActivity(id: UUID(), queueID: item.id, title: item.title)
        activity.phase = "Downloading"
        activity.progress = 0.35
        activity.bytesPerSecond = 1_000
        let sessionStore = MemorySessionStore(snapshot: NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            operations: [NativeDownloadOperation(
                queueID: item.id,
                activityID: activity.id,
                status: .downloading
            )],
            selectedQueueID: item.id,
            linkInbox: []
        ))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            sessionStore: sessionStore
        )

        viewModel.start()

        XCTAssertEqual(viewModel.queue.first.map(viewModel.status(for:)), .paused)
        XCTAssertEqual(viewModel.queue.first?.downloadQuality, .lossless)
        XCTAssertEqual(viewModel.queue.first?.downloadRootPath, paths.defaultDownloadRoot.path)
        XCTAssertEqual(viewModel.activities.first.map(viewModel.status(for:)), .paused)
        XCTAssertEqual(viewModel.activities.first?.phase, "Paused after interruption")
        XCTAssertNil(viewModel.activities.first?.bytesPerSecond)
        XCTAssertEqual(viewModel.selectedQueueID, item.id)
        XCTAssertFalse(viewModel.canClearActivity)
        viewModel.prepareForTermination()
        XCTAssertEqual(sessionStore.snapshot?.operations.first?.status, .paused)
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

    func testPastedAlbumLinkOpensVerifiedBrowsePageBeforeQueueing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in service }
        )

        viewModel.start()
        viewModel.addText("https://www.qobuz.com/fr-fr/album/30/30")

        XCTAssertTrue(viewModel.queue.isEmpty)
        XCTAssertEqual(viewModel.browsePath.last?.destination, .album(QobuzID("30")))

        for _ in 0..<100 where viewModel.browsePath.last?.content == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .album(let album)? = viewModel.browsePath.last?.content else {
            return XCTFail("Expected an account-verified album detail")
        }
        XCTAssertEqual(viewModel.browsePath.last?.availability, .available)
        XCTAssertTrue(viewModel.queue.isEmpty)

        viewModel.addRequest(
            .album(album.id),
            title: album.displayTitle,
            subtitle: album.artist.name,
            artworkURL: album.image?.bestURL
        )

        XCTAssertEqual(viewModel.queue.map(\.request), [.album(QobuzID("30"))])
        XCTAssertEqual(viewModel.queue.first?.subtitle, "Adele")
        XCTAssertEqual(viewModel.queue.first?.artworkURL, URL(string: "https://example.com/30.jpg"))
    }

    func testBrowserHandoffOpensPercentEncodedQobuzURLInBrowse() throws {
        for scheme in ["orpheus-for-mac", "orpheus-native"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
            let viewModel = NativeViewModel(
                paths: paths,
                settingsStore: NativeSettingsStore(paths: paths),
                credentialStore: MemoryCredentialStore(credentials: .complete),
                clientFactory: { _ in FakeQobuzService() }
            )
            var components = URLComponents()
            components.scheme = scheme
            components.host = "open"
            components.queryItems = [
                URLQueryItem(name: "url", value: "https://www.qobuz.com/fr-fr/album/30/30")
            ]

            viewModel.start()
            viewModel.handleOpenURL(try XCTUnwrap(components.url))

            XCTAssertEqual(viewModel.browsePath.last?.destination, .album(QobuzID("30")), scheme)
            XCTAssertTrue(viewModel.queue.isEmpty, scheme)
        }
    }

    func testSeveralPastedLinksEnterReviewedInboxAndNeverMutateQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in service }
        )

        viewModel.start()
        viewModel.addText("https://open.qobuz.com/album/a\nhttps://play.qobuz.com/album/b")

        for _ in 0..<100 where viewModel.linkInbox.contains(where: {
            $0.status == .pending || $0.status == .checking
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(viewModel.queue.isEmpty)
        XCTAssertTrue(viewModel.browsePath.isEmpty)
        XCTAssertEqual(viewModel.linkInbox.map(\.request), [.album(QobuzID("a")), .album(QobuzID("b"))])
        XCTAssertTrue(viewModel.linkInbox.allSatisfy { $0.status == .available })

        let firstID = try XCTUnwrap(viewModel.linkInbox.first?.id)
        viewModel.openInboxItem(firstID)
        XCTAssertEqual(viewModel.browsePath.last?.destination, .album(QobuzID("a")))
    }

    func testInboxClassifiesAccountRegionMissAsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in FakeQobuzService() }
        )

        viewModel.start()
        viewModel.addText(
            "https://open.qobuz.com/album/a\nhttps://open.qobuz.com/album/missing-region"
        )
        for _ in 0..<100 where viewModel.linkInbox.contains(where: {
            $0.status == .pending || $0.status == .checking
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let blocked = try XCTUnwrap(
            viewModel.linkInbox.first { $0.request == .album(QobuzID("missing-region")) }
        )
        guard case .unavailable(let message) = blocked.status else {
            return XCTFail("Expected an account-region availability result")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("account"))
        XCTAssertTrue(viewModel.queue.isEmpty)
    }

    func testLabelLinkOpensAccountVerifiedLabelWithoutQueueing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in FakeQobuzService() }
        )

        viewModel.start()
        viewModel.addText("https://www.qobuz.com/us-en/label/example/download-streaming-albums/4587")
        for _ in 0..<100 where viewModel.browsePath.last?.content == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .label(let label)? = viewModel.browsePath.last?.content else {
            return XCTFail("Expected a label detail page")
        }
        XCTAssertEqual(label.name, "Test Label")
        XCTAssertEqual(viewModel.browsePath.last?.availability, .available)
        XCTAssertTrue(viewModel.queue.isEmpty)
    }

    func testMixedAlbumAvailabilityAllowsQueueAndExplainsSkippedTracks() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore()
        )
        let album = QobuzAlbum(
            id: QobuzID("mixed"),
            title: "Mixed",
            artist: QobuzArtist(id: QobuzID("artist"), name: "Artist"),
            tracks: [
                QobuzTrack(id: QobuzID("available"), title: "Available"),
                QobuzTrack(id: QobuzID("region-blocked"), title: "Blocked", streamable: false),
                QobuzTrack(id: QobuzID("store-blocked"), title: "Store Blocked", purchasable: false)
            ]
        )

        guard case .partial(let message) = viewModel.availability(for: album) else {
            return XCTFail("Expected partial availability")
        }
        XCTAssertTrue(viewModel.availability(for: album).allowsQueue)
        XCTAssertEqual(album.availableTracks.map(\.id), [QobuzID("available")])
        XCTAssertTrue(message.contains("1 of 3 tracks"))
        XCTAssertNotNil(viewModel.unavailabilityMessage(for: album.tracks[1]))
        XCTAssertNotNil(viewModel.unavailabilityMessage(for: album.tracks[2]))
    }

    func testAdeleSearchPopulatesVisibleBrowseStateAndPreservesSelectedCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            paths: paths,
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
        XCTAssertEqual(viewModel.browsePlaylists.map(\.name), ["Adele Essentials"])
        XCTAssertEqual(viewModel.browseTracks.map(\.title), ["Hello"])
        XCTAssertEqual(viewModel.browseCategory, .tracks)
        XCTAssertEqual(viewModel.browseStatusText, "5 results")
        XCTAssertFalse(viewModel.isBrowseLoading)
    }

    func testSearchLoadsASecondCategoryPageAndUpdatesLoadedCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService(paginatedSearch: true)
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: .complete),
            clientFactory: { _ in service }
        )

        viewModel.start()
        viewModel.search("Sting")
        for _ in 0..<100 where viewModel.isBrowseLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.browseTracks.map(\.title), ["Track One", "Track Two"])
        XCTAssertEqual(viewModel.browseCountLabel(for: .tracks), "2+")
        XCTAssertEqual(viewModel.browseStatusText, "2 loaded")
        XCTAssertTrue(viewModel.canLoadMoreBrowseResults(for: .tracks))

        viewModel.loadMoreBrowseResults(for: .tracks)
        for _ in 0..<100 where viewModel.isLoadingMoreBrowseResults(for: .tracks) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.browseTracks.map(\.title), ["Track One", "Track Two", "Track Three"])
        XCTAssertEqual(viewModel.browseCountLabel(for: .tracks), "3")
        XCTAssertEqual(viewModel.browseStatusText, "3 results")
        XCTAssertFalse(viewModel.canLoadMoreBrowseResults(for: .tracks))
    }

    func testBrowseDrillDownOpensAlbumPageAndBackReturnsToResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(applicationSupportRoot: root, defaultDownloadRoot: root.appendingPathComponent("Music"))
        let service = FakeQobuzService()
        let viewModel = NativeViewModel(
            paths: paths,
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
            paths: paths,
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
            paths: paths,
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
            paths: paths,
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
            paths: paths,
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
            paths: paths,
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
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore()
        )
        let damaged = Self.archiveTrack(
            relativePath: "Artist/Album/01.flac",
            trackID: "damaged",
            albumID: "album",
            formatID: QobuzAudioFormat.hiRes96.formatID,
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
        viewModel.addRequest(.track(QobuzID("damaged")), title: "Normal track download")
        let originalQueueID = viewModel.queue.first?.id

        let firstIDs = viewModel.stageArchiveRepairs([damaged, damaged, verified, unsupported])
        let secondIDs = viewModel.stageArchiveRepairs([damaged])

        XCTAssertEqual(firstIDs, [originalQueueID].compactMap { $0 })
        XCTAssertEqual(secondIDs, firstIDs)
        XCTAssertEqual(viewModel.queue.count, 1)
        XCTAssertEqual(viewModel.queue[0].repairTarget, damaged)
        XCTAssertEqual(viewModel.queue[0].subtitle, "Repair · Hi-Res FLAC up to 96 kHz")
        XCTAssertNil(viewModel.queue[0].downloadQuality)
    }

    private func restoredViewModel(
        status: NativeDownloadStatus,
        item: NativeQueueItem,
        activity: NativeDownloadActivity,
        paths: NativePaths
    ) -> NativeViewModel {
        let sessionStore = MemorySessionStore(snapshot: NativeSessionSnapshot(
            queue: [item],
            activities: [activity],
            operations: [NativeDownloadOperation(
                queueID: item.id,
                activityID: activity.id,
                status: status
            )],
            selectedQueueID: item.id,
            linkInbox: []
        ))
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(),
            sessionStore: sessionStore
        )
        viewModel.start()
        return viewModel
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
            integrity: integrity,
            archiveKind: .album
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

@MainActor
private final class FakeConnectivityMonitor: NativeConnectivityMonitoring {
    private(set) var state: NativeConnectivityState = .unknown
    private var handler: ((NativeConnectivityState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onChange: @escaping @MainActor (NativeConnectivityState) -> Void) {
        startCount += 1
        handler = onChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ state: NativeConnectivityState) {
        self.state = state
        handler?(state)
    }
}

@MainActor
private final class FakePowerActivityManager: NativePowerActivityManaging {
    private(set) var beginReasons: [String] = []
    private(set) var endCount = 0

    func begin(reason: String) -> NSObjectProtocol {
        beginReasons.append(reason)
        return NSObject()
    }

    func end(_ token: NSObjectProtocol) {
        endCount += 1
    }
}

private extension CredentialDraft {
    static let complete = CredentialDraft(appID: "app-id", appSecret: "app-secret", authToken: "token")
}

private final class FakeQobuzService: NativeQobuzServicing, @unchecked Sendable {
    private let paginatedSearch: Bool

    init(paginatedSearch: Bool = false) {
        self.paginatedSearch = paginatedSearch
    }

    func validateAccount() async throws -> String? { "FR" }

    func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int,
        offset: Int
    ) async throws -> QobuzSearchResults {
        try await Task.sleep(for: .milliseconds(30))
        if paginatedSearch {
            guard category == .tracks else {
                return QobuzSearchResults(offset: offset, total: 0)
            }
            if offset == 0 {
                return QobuzSearchResults(
                    tracks: [
                        QobuzTrack(id: .init("track-one"), title: "Track One"),
                        QobuzTrack(id: .init("track-two"), title: "Track Two")
                    ],
                    nextOffset: 2,
                    total: 3
                )
            }
            return QobuzSearchResults(
                tracks: [QobuzTrack(id: .init("track-three"), title: "Track Three")],
                offset: offset,
                total: 3
            )
        }
        switch category {
        case .albums:
            return QobuzSearchResults(albums: [
                QobuzAlbumSummary(id: .init("30"), title: "30", artist: .init(id: .init("adele"), name: "Adele")),
                QobuzAlbumSummary(id: .init("19"), title: "19", artist: .init(id: .init("adele"), name: "Adele"))
            ])
        case .artists:
            return QobuzSearchResults(artists: [.init(id: .init("adele"), name: "Adele")])
        case .playlists:
            return QobuzSearchResults(playlists: [
                QobuzPlaylist(
                    id: .init("adele-essentials"),
                    name: "Adele Essentials",
                    tracks: [],
                    owner: .init(name: "Qobuz"),
                    tracksCount: 20
                )
            ])
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
        if id == QobuzID("missing-region") {
            throw NativeQobuzError.unavailable("Album is unavailable for this account region.")
        }
        return QobuzAlbum(
            id: id,
            title: "30",
            artist: .init(id: .init("adele"), name: "Adele"),
            image: QobuzImage(large: URL(string: "https://example.com/30.jpg")),
            tracks: [QobuzTrack(id: .init("easy"), title: "Easy On Me", trackNumber: 1)],
            maximumSamplingRate: 96,
            maximumBitDepth: 24,
            hiresStreamable: true
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

    func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        return QobuzLabelCatalog(
            id: id,
            name: "Test Label",
            albums: [QobuzAlbum(id: QobuzID("release"), title: "Release", artist: artist)]
        )
    }

    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo {
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
