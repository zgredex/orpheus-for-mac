import AppKit
import Combine
import Foundation
import NativeQobuzCore

@MainActor
final class NativeViewModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var activities: [NativeDownloadActivity] = [] {
        didSet { scheduleSessionPersistence() }
    }
    @Published var notice: String?
    @Published var showSettings = false
    @Published var showDiagnostics = false

    @Published private(set) var isLibraryOpen = false
    @Published private(set) var archiveSnapshot: QobuzArchiveSnapshot?
    @Published private(set) var isArchiveScanning = false
    @Published private(set) var connectivityState: NativeConnectivityState = .unknown

    private let archiveStore: any NativeArchiveIndexStoring
    private let sessionStore: any NativeSessionStoring
    private let diagnostics: NativeDiagnosticsController
    private let archiveScanner: any QobuzArchiveScanning
    private let libraryAdopter: any QobuzLibraryAdopting
    private let connectivityMonitor: any NativeConnectivityMonitoring
    private let powerActivityManager: any NativePowerActivityManaging
    private let account: NativeAccountController
    private let browse = NativeBrowseController()
    private let queueController = NativeQueueController()
    private let previewController = NativePreviewController()
    private let linkInboxController = NativeLinkInboxController()
    private var archiveTask: Task<Void, Never>?
    private var archiveRefreshID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var activeItemDownloadTask: Task<Void, Never>?
    private var activeItemQueueID: UUID?
    private var sessionPersistenceTask: Task<Void, Never>?
    private var lastProgressUpdate: [UUID: Date] = [:]
    private var downloadState = NativeDownloadStateStore()
    private var started = false
    private var restoringSession = false
    private var isTerminating = false
    private var connectivityGeneration: UInt64 = 0
    private var accountObservation: AnyCancellable?
    private var browseObservation: AnyCancellable?
    private var queueObservation: AnyCancellable?
    private var previewObservation: AnyCancellable?
    private var linkInboxObservation: AnyCancellable?
    private let connectivityEvents = NativeConnectivityEvents()
    private let reusableAudioIndex = QobuzReusableAudioIndex()

    init(
        paths: NativePaths,
        settingsStore: (any NativeSettingsStoring)? = nil,
        credentialStore: (any NativeCredentialStoring)? = nil,
        archiveStore: (any NativeArchiveIndexStoring)? = nil,
        sessionStore: (any NativeSessionStoring)? = nil,
        logStore: (any NativeLogStoring)? = nil,
        supplementalDiagnosticsCollector: (any NativeSupplementalDiagnosticsCollecting)? = nil,
        archiveScanner: any QobuzArchiveScanning = QobuzArchiveScanner(),
        libraryAdopter: (any QobuzLibraryAdopting)? = nil,
        connectivityMonitor: (any NativeConnectivityMonitoring)? = nil,
        powerActivityManager: (any NativePowerActivityManaging)? = nil,
        clientFactory: @escaping (QobuzCredentials) -> any NativeQobuzServicing = {
            QobuzAPIClient(credentials: $0)
        }
    ) {
        account = NativeAccountController(
            paths: paths,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            clientFactory: clientFactory
        )
        self.archiveStore = archiveStore ?? NativeArchiveIndexStore(paths: paths)
        self.sessionStore = sessionStore ?? NativeSessionStore(paths: paths)
        diagnostics = NativeDiagnosticsController(
            logStore: logStore ?? NativeLogFileStore(paths: paths),
            supplementalCollector: supplementalDiagnosticsCollector ?? NativeSupplementalDiagnosticsCollector()
        )
        self.archiveScanner = archiveScanner
        self.libraryAdopter = libraryAdopter ?? QobuzLibraryAdopter(scanner: archiveScanner)
        self.connectivityMonitor = connectivityMonitor ?? NativeNetworkConnectivityMonitor()
        self.powerActivityManager = powerActivityManager ?? NativePowerActivityManager()
        accountObservation = account.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        browseObservation = browse.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        queueObservation = queueController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleSessionPersistence()
        }
        previewObservation = previewController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        linkInboxObservation = linkInboxController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleSessionPersistence()
        }
        do {
            try diagnostics.activate()
            qobuzLog.info("lifecycle", "Native view model initialized")
        } catch {
            FileHandle.standardError.write(Data("Could not activate diagnostics: \(error.localizedDescription)\n".utf8))
        }
    }

    var queue: [NativeQueueItem] { queueController.items }
    var selectedQueueID: UUID? { queueController.selectedID }
    var selectedQueueItem: NativeQueueItem? { queueController.selectedItem }
    var preview: NativePreviewState { previewController.state }
    var linkInbox: [NativeLinkInboxItem] { linkInboxController.items }

    func queueTrackSelection(for request: QobuzRequest) -> Set<QobuzID>? {
        guard let item = selectedQueueItem,
              item.request == request,
              item.trackPlan != nil else { return nil }
        return item.effectiveSelectedTrackIDs
    }

    func toggleSelectedQueueTrack(_ trackID: QobuzID) {
        guard let selectedQueueID else { return }
        toggleQueueTrack(trackID, in: selectedQueueID)
    }

    func selectAllSelectedQueueTracks() {
        guard let selectedQueueID else { return }
        selectAllQueueTracks(in: selectedQueueID)
    }

    func clearSelectedQueueTracks() {
        guard let selectedQueueID else { return }
        clearQueueTrackSelection(in: selectedQueueID)
    }

    var canDownloadSelected: Bool {
        !isDownloading
            && selectedQueueItem.map(isQueueItemStartable) == true
            && credentials.isComplete
    }

    var canDownloadAll: Bool {
        !isDownloading && credentials.isComplete && queue.contains(where: isQueueItemStartable)
    }

    var canDownloadNext: Bool { canDownloadAll }

    var isDownloading: Bool { downloadTask != nil }
    var canCancel: Bool { downloadTask != nil }
    var canClearActivity: Bool { activities.contains { status(for: $0).isClearable } }
    var settings: NativeSettings { account.settings }
    var credentials: CredentialDraft { account.credentials }
    var accountRegion: String? { account.accountRegion }
    private var client: (any NativeQobuzServicing)? { account.client }
    var browseQuery: String { browse.query }
    var browseCategory: NativeBrowseCategory {
        get { browse.category }
        set { browse.category = newValue }
    }
    var browseResults: NativeBrowseResults { browse.results }
    var loadingBrowseCategories: Set<NativeBrowseCategory> { browse.loadingCategories }
    var loadingMoreBrowseCategories: Set<NativeBrowseCategory> { browse.loadingMoreCategories }
    var browseErrors: [NativeBrowseCategory: String] { browse.errors }
    var browseLoadMoreErrors: [NativeBrowseCategory: String] { browse.loadMoreErrors }
    var isBrowseOpen: Bool { browse.isOpen }
    var browsePath: [BrowsePage] { browse.path }
    var isBrowseLoading: Bool { browse.isLoading }
    var browseStatusText: String { browse.statusText }
    var browseAlbums: [QobuzAlbumSummary] { browse.albums }
    var browseArtists: [QobuzArtist] { browse.artists }
    var browsePlaylists: [QobuzPlaylist] { browse.playlists }
    var browseTracks: [QobuzTrack] { browse.tracks }

    var regionDisplay: String { account.regionDisplay }

    var diagnosticsDirectoryPath: String { diagnostics.directoryURL.path }

    func status(for item: NativeQueueItem) -> NativeDownloadStatus {
        downloadState.status(forQueueID: item.id)
    }

    func status(for activity: NativeDownloadActivity) -> NativeDownloadStatus {
        downloadState.status(forActivityID: activity.id) ?? .ready
    }

    func detailError(for activity: NativeDownloadActivity) -> String? {
        activity.errorMessage ?? status(for: activity).failureMessage
    }

    func diagnosticEntries(limit: Int = 5_000) throws -> [QobuzLogEntry] {
        try diagnostics.entries(limit: limit)
    }

    func clearDiagnostics() throws {
        try diagnostics.clear()
    }

    func revealDiagnostics() {
        diagnostics.reveal()
    }

    @discardableResult
    func exportDiagnostics(to parent: URL) async throws -> URL {
        try await diagnostics.export(report: makeDiagnosticReport(), to: parent)
    }

    func start() {
        guard !started else {
            qobuzLog.debug("lifecycle", "Ignored duplicate app startup request")
            return
        }
        started = true
        connectivityMonitor.start { [weak self] state in
            self?.applyConnectivityState(state)
        }
        let startedAt = Date()
        qobuzLog.notice("lifecycle", "Native app startup started")
        do {
            try account.load()
            qobuzLog.info(
                "lifecycle",
                "Startup configuration loaded",
                metadata: [
                    "credentialsConfigured": String(credentials.isComplete),
                    "downloadPath": settings.downloadPath,
                    "quality": settings.quality.rawValue
                ]
            )
            loadArchiveCache()
            do {
                try restoreSession()
            } catch {
                qobuzLog.error("persistence.session", "Download queue restoration failed", error: error)
                notice = "Could not restore the download queue: \(error.localizedDescription)"
            }
            synchronizeBrowseAccount()
            if let selectedQueueID,
               let item = queue.first(where: { $0.id == selectedQueueID }) {
                loadPreview(item)
            }
            if credentials.isComplete {
                Task { await testConnection(showSuccess: false) }
            } else {
                showSettings = true
            }
            persistSessionNow(reportErrors: false)
            qobuzLog.notice(
                "lifecycle",
                "Native app startup completed",
                metadata: [
                    "queueCount": String(queue.count),
                    "activityCount": String(activities.count),
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ]
            )
        } catch {
            qobuzLog.critical(
                "lifecycle",
                "Native app startup failed",
                metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))],
                error: error
            )
            notice = "Could not load native settings: \(error.localizedDescription)"
            showSettings = true
        }
    }

    var settingsDraft: SettingsDraft {
        account.draft
    }

    func saveConfiguration(_ draft: SettingsDraft) throws {
        let change = try account.save(draft, downloadIsActive: isDownloading)
        applyConfigurationChange(change)
    }

    func saveConfiguration(credentials: CredentialDraft, settings: NativeSettings) throws {
        let change = try account.save(
            credentials: credentials,
            settings: settings,
            downloadIsActive: isDownloading
        )
        applyConfigurationChange(change)
    }

    func testConnection(showSuccess: Bool = true) async {
        do {
            _ = try await account.validateConnection()
            synchronizeBrowseAccount()
            if showSuccess { notice = "Connected to the \(regionDisplay) Qobuz account." }
        } catch {
            synchronizeBrowseAccount()
            notice = error.localizedDescription
        }
    }

    func submitInput() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let extraction = QobuzLinkParser.extract(from: value)
        qobuzLog.info(
            "input",
            "User input classified",
            metadata: [
                "characterCount": String(value.count),
                "validLinks": String(extraction.links.count),
                "duplicateLinks": String(extraction.duplicateCount),
                "invalidQobuzLinks": String(extraction.invalidQobuzURLs.count),
                "mode": extraction.links.isEmpty ? "search" : "links"
            ]
        )
        if extraction.links.count == 1, extraction.duplicateCount == 0,
           let link = extraction.links.first {
            openRequest(link.request)
            input = ""
            notice = extraction.invalidQobuzURLs.isEmpty
                ? nil
                : "Ignored \(extraction.invalidQobuzURLs.count) invalid Qobuz URL."
        } else if !extraction.links.isEmpty {
            reviewLinks(extraction.links)
            input = ""
            let invalid = extraction.invalidQobuzURLs.count
            notice = invalid > 0 ? "Added the valid links for review and ignored \(invalid) unsupported Qobuz URL\(invalid == 1 ? "" : "s")." : nil
        } else if !extraction.invalidQobuzURLs.isEmpty {
            notice = "The Qobuz URL is not a supported track, album, playlist, artist, or label link."
        } else {
            search(value)
            input = ""
        }
    }

    func addText(_ text: String) {
        input = text
        submitInput()
    }

    func importLinks(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            qobuzLog.notice(
                "input.import",
                "Link text file imported",
                metadata: ["sourcePath": url.path, "characterCount": String(text.count)]
            )
            addText(text)
        } catch {
            qobuzLog.error(
                "input.import",
                "Link text file could not be read",
                metadata: ["sourcePath": url.path],
                error: error
            )
            notice = "Could not read the text file: \(error.localizedDescription)"
        }
    }

    func handleOpenURL(_ url: URL) {
        if ["orpheus-for-mac", "orpheus-native"].contains(url.scheme?.lowercased() ?? "") {
            guard let submitted = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value else {
                notice = "The Orpheus link did not contain a Qobuz URL."
                return
            }
            addText(submitted)
        } else {
            addText(url.absoluteString)
        }
    }

    func openInboxItem(_ id: UUID) {
        guard let item = linkInboxController.item(id) else { return }
        openRequest(item.request)
    }

    func removeInboxItem(_ id: UUID) {
        linkInboxController.remove(id)
    }

    func clearReviewedLinks() {
        linkInboxController.clearReviewed()
    }

    func clearLinkInbox() {
        linkInboxController.clear()
    }

    func retryInboxItem(_ id: UUID) {
        if linkInboxController.retry(id) { showSettings = true }
    }

    private func reviewLinks(_ links: [ParsedQobuzLink]) {
        let result = linkInboxController.add(links)
        if result.duplicateOnly {
            notice = "Those links are already in the review inbox."
        }
        if result.requiresConfiguration { showSettings = true }
    }

    func addRequest(
        _ request: QobuzRequest,
        title: String? = nil,
        subtitle: String? = nil,
        artworkURL: URL? = nil
    ) {
        guard let item = queueController.add(
            request,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL
        ) else {
            notice = "That Qobuz item is already queued."
            return
        }
        updateDownloadState { $0.registerQueue(item.id) }
        loadPreview(item)
    }

    func addAlbums(_ albums: [QobuzAlbum]) {
        let result = queueController.addAlbums(albums)
        guard !result.added.isEmpty else {
            if result.skipped > 0 { notice = "Those editions are already queued." }
            return
        }
        updateDownloadState { $0.registerQueues(result.added.map(\.id)) }
        loadPreview(result.added[0])
        if result.skipped > 0 {
            let noun = result.skipped == 1 ? "edition" : "editions"
            notice = "Skipped \(result.skipped) already queued \(noun)."
        } else {
            notice = nil
        }
    }

    func selectQueueItem(_ id: UUID?) {
        guard let item = queueController.select(id) else {
            previewController.clear()
            return
        }
        loadPreview(item)
    }

    func removeQueueItem(_ id: UUID) {
        let result = queueController.remove(
            id,
            isActive: downloadState.status(forQueueID: id).isActive
        )
        guard result.removedID != nil else { return }
        updateDownloadState { $0.removeQueue(id) }
        if let selectedItem = result.selectedItem { loadPreview(selectedItem) }
        else { previewController.clear() }
    }

    func clearQueue() {
        let activeIDs = Set(queue.filter { status(for: $0).isActive }.map(\.id))
        let result = queueController.clear(retaining: activeIDs)
        updateDownloadState { state in
            for id in result.removedIDs { state.removeQueue(id) }
        }
        if let selectedItem = result.selectedItem { loadPreview(selectedItem) }
        else { previewController.clear() }
    }

    func setQueueQuality(_ quality: QobuzQuality?, for id: UUID) {
        guard queueController.setQuality(quality, for: id, mutationsAllowed: !isDownloading) else { return }
        resetQueueStatusAfterPlanChange(id)
    }

    func toggleQueueTrack(_ trackID: QobuzID, in id: UUID) {
        guard queueController.toggleTrack(trackID, in: id, mutationsAllowed: !isDownloading) else { return }
        resetQueueStatusAfterPlanChange(id)
    }

    func selectAllQueueTracks(in id: UUID) {
        guard queueController.selectAllTracks(in: id, mutationsAllowed: !isDownloading) else { return }
        resetQueueStatusAfterPlanChange(id)
    }

    func clearQueueTrackSelection(in id: UUID) {
        guard queueController.clearTrackSelection(in: id, mutationsAllowed: !isDownloading) else { return }
        resetQueueStatusAfterPlanChange(id)
    }

    func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        queueController.move(from: offsets, to: destination, mutationsAllowed: !isDownloading)
    }

    func moveQueueItem(_ sourceID: UUID, before targetID: UUID) {
        queueController.move(sourceID, before: targetID, mutationsAllowed: !isDownloading)
    }

    func moveQueueItemUp(_ id: UUID) {
        queueController.moveUp(id, mutationsAllowed: !isDownloading)
    }

    func moveQueueItemDown(_ id: UUID) {
        queueController.moveDown(id, mutationsAllowed: !isDownloading)
    }

    func queuePreflight(for item: NativeQueueItem) -> NativeQueuePreflight {
        queueController.preflight(for: item, archiveSnapshot: archiveSnapshot)
    }

    func search(_ query: String) {
        isLibraryOpen = false
        do {
            try browse.search(query)
        } catch {
            notice = error.localizedDescription
            showSettings = true
        }
    }

    func closeBrowse() {
        browse.close()
    }

    func openAlbum(_ id: QobuzID) {
        openBrowseDestination(.album(id))
    }

    func openArtist(_ id: QobuzID) {
        openBrowseDestination(.artist(id))
    }

    func openTrack(_ id: QobuzID) {
        openBrowseDestination(.track(id))
    }

    func openPlaylist(_ id: QobuzID) {
        openBrowseDestination(.playlist(id))
    }

    func openLabel(_ id: QobuzID) {
        openBrowseDestination(.label(id))
    }

    func openRequest(_ request: QobuzRequest) {
        isLibraryOpen = false
        do {
            try browse.open(request)
        } catch {
            notice = error.localizedDescription
            showSettings = true
        }
    }

    func browseBack() {
        browse.back()
    }

    func retryBrowsePage() {
        do {
            try browse.retryPage()
        } catch {
            notice = error.localizedDescription
            showSettings = true
        }
    }

    private func openBrowseDestination(_ destination: BrowseDestination) {
        isLibraryOpen = false
        do {
            try browse.open(destination)
        } catch {
            notice = error.localizedDescription
            showSettings = true
        }
    }

    func availability(for album: QobuzAlbum) -> NativeBrowseAvailability {
        browse.availability(for: album)
    }

    func availability(for track: QobuzTrack) -> NativeBrowseAvailability {
        browse.availability(for: track)
    }

    func availability(for playlist: QobuzPlaylist) -> NativeBrowseAvailability {
        browse.availability(for: playlist)
    }

    func availability(for artist: QobuzArtistCatalog) -> NativeBrowseAvailability {
        browse.availability(for: artist)
    }

    func availability(for label: QobuzLabelCatalog) -> NativeBrowseAvailability {
        browse.availability(for: label)
    }

    func unavailabilityMessage(for track: QobuzTrack) -> String? {
        browse.unavailabilityMessage(for: track)
    }

    func retryBrowseSearch() {
        do {
            try browse.retrySearch()
        } catch {
            notice = error.localizedDescription
            showSettings = true
        }
    }

    func openLibrary() {
        browse.close()
        isLibraryOpen = true
        qobuzLog.notice("library.ui", "Library opened", metadata: ["downloadRoot": settings.downloadPath])

        if archiveSnapshot == nil {
            do {
                if let cached = try archiveStore.load(),
                   cached.rootPath == URL(fileURLWithPath: settings.downloadPath).standardizedFileURL.path {
                    archiveSnapshot = cached
                    qobuzLog.debug(
                        "library.ui",
                        "Displayed cached library snapshot",
                        metadata: ["trackCount": String(cached.tracks.count), "problemCount": String(cached.problemCount)]
                    )
                }
            } catch {
                qobuzLog.warning("library.ui", "Cached library snapshot could not be displayed", error: error)
            }
        }
        refreshArchive()
    }

    func closeLibrary() {
        archiveTask?.cancel()
        archiveTask = nil
        archiveRefreshID = nil
        isArchiveScanning = false
        isLibraryOpen = false
        qobuzLog.debug("library.ui", "Library closed")
    }

    func refreshArchive(fullVerification: Bool = false) {
        archiveTask?.cancel()
        let root = URL(fileURLWithPath: settings.downloadPath, isDirectory: true).standardizedFileURL
        let refreshToken = UUID()
        archiveRefreshID = refreshToken
        let refreshID = refreshToken.uuidString
        qobuzLog.notice(
            "library.refresh",
            "Library refresh requested",
            metadata: ["libraryRefreshID": refreshID, "downloadRoot": root.path]
        )
        isArchiveScanning = true
        archiveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if archiveRefreshID == refreshToken {
                    isArchiveScanning = false
                    archiveTask = nil
                    archiveRefreshID = nil
                }
            }
            do {
                let snapshot = try await QobuzLogScope.withValue(["libraryRefreshID": refreshID]) {
                    try await self.archiveScanner.scan(
                        root: root,
                        reusing: fullVerification ? nil : self.archiveSnapshot
                    )
                }
                try Task.checkCancellation()
                let currentRoot = URL(
                    fileURLWithPath: settings.downloadPath,
                    isDirectory: true
                ).standardizedFileURL.path
                guard currentRoot == root.path else { return }
                archiveSnapshot = snapshot
                try archiveStore.save(snapshot)
                qobuzLog.notice(
                    "library.refresh",
                    "Library refresh applied",
                    metadata: [
                        "libraryRefreshID": refreshID,
                        "trackCount": String(snapshot.tracks.count),
                        "problemCount": String(snapshot.problemCount)
                    ]
                )
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice(
                    "library.refresh",
                    "Library refresh cancelled",
                    metadata: ["libraryRefreshID": refreshID]
                )
                return
            } catch {
                qobuzLog.error(
                    "library.refresh",
                    "Library refresh failed",
                    metadata: ["libraryRefreshID": refreshID],
                    error: error
                )
                notice = "Could not scan the library: \(error.localizedDescription)"
            }
        }
    }

    func inspectLibraryForAdoption(at root: URL) async throws -> QobuzLibraryAdoptionPlan {
        guard !isDownloading else {
            throw NativeQobuzError.unavailable("A Library cannot be adopted during an active download.")
        }
        let adoptionID = UUID().uuidString
        qobuzLog.notice(
            "library.adoption.ui",
            "Library adoption inspection requested",
            metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        )
        do {
            return try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
                try await libraryAdopter.inspect(root: root)
            }
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                "Library adoption inspection failed",
                metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func adoptLibrary(at root: URL, draft: SettingsDraft) async throws {
        guard !isDownloading else {
            throw NativeQobuzError.unavailable("A Library cannot be adopted during an active download.")
        }
        let adoptionID = UUID().uuidString
        qobuzLog.notice(
            "library.adoption.ui",
            "Library adoption confirmed",
            metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        )
        do {
            let result = try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
                try await libraryAdopter.adopt(root: root)
            }
            try saveConfiguration(
                credentials: draft.credentials,
                settings: NativeSettings(
                    downloadPath: result.plan.root.path,
                    quality: draft.quality
                )
            )
            archiveSnapshot = result.snapshot
            try archiveStore.save(result.snapshot)
            isArchiveScanning = false
            isLibraryOpen = true
            browse.close()
            showSettings = false
            let repaired = result.plan.manifestAction != .none
            notice = repaired
                ? "Existing Library adopted and its index was rebuilt."
                : "Existing Library adopted and verified."
            qobuzLog.notice(
                "library.adoption.ui",
                "Adopted Library became the active download root",
                metadata: [
                    "libraryAdoptionID": adoptionID,
                    "downloadRoot": result.plan.root.path,
                    "trackCount": String(result.snapshot.tracks.count),
                    "problemCount": String(result.snapshot.problemCount),
                    "manifestAction": result.plan.manifestAction.rawValue
                ]
            )
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                "Library adoption failed",
                metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func revealArchiveTrack(_ track: QobuzArchiveTrack) {
        revealArchivePath(track.relativePath)
    }

    func revealArchiveEntry(_ entry: QobuzArchiveEntry) {
        revealArchivePath(entry.relativePath)
    }

    func revealArchiveIssue(_ issue: NativeLibraryIndexProblem) {
        revealArchivePath(issue.relativePath, allowingRoot: true)
    }

    private func revealArchivePath(_ relativePath: String, allowingRoot: Bool = false) {
        guard let snapshot = archiveSnapshot else { return }
        let root = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true).standardizedFileURL
        guard let target = QobuzPathSafety.containedURL(
            for: relativePath,
            in: root,
            allowingRoot: allowingRoot
        ),
              FileManager.default.fileExists(atPath: target.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func libraryStatus(for item: NativeQueueItem) -> NativeLibraryStatus? {
        guard let snapshot = archiveSnapshot else { return nil }
        let coverage: QobuzArchiveCoverage
        switch item.request {
        case .track(let id):
            coverage = snapshot.coverage(trackID: id)
        case .album(let id):
            let trackIDs = item.selectedTrackIDs.map(Array.init) ?? item.expectedTrackIDs
            if let trackIDs, !trackIDs.isEmpty {
                coverage = snapshot.coverage(trackIDs: trackIDs, albumID: id)
            } else if item.selectedTrackIDs != nil {
                return nil
            } else {
                coverage = snapshot.coverage(albumID: id)
            }
        case .playlist:
            let trackIDs = item.selectedTrackIDs.map(Array.init) ?? item.expectedTrackIDs
            guard let trackIDs, !trackIDs.isEmpty else { return nil }
            coverage = snapshot.coverage(trackIDs: trackIDs)
        case .artist, .label:
            return nil
        }
        return NativeLibraryStatus(coverage)
    }

    func libraryStatus(for album: QobuzAlbumSummary) -> NativeLibraryStatus? {
        guard let snapshot = archiveSnapshot else { return nil }
        return NativeLibraryStatus(snapshot.coverage(albumID: album.id))
    }

    func libraryStatus(for album: QobuzAlbum) -> NativeLibraryStatus? {
        guard let snapshot = archiveSnapshot else { return nil }
        let trackIDs = album.availableTracks.map(\.id)
        let coverage = trackIDs.isEmpty
            ? snapshot.coverage(albumID: album.id)
            : snapshot.coverage(trackIDs: trackIDs, albumID: album.id)
        return NativeLibraryStatus(coverage)
    }

    func libraryStatus(for track: QobuzTrack) -> NativeLibraryStatus? {
        guard let snapshot = archiveSnapshot else { return nil }
        return NativeLibraryStatus(snapshot.coverage(trackID: track.id, albumID: track.album?.id))
    }

    func libraryStatus(for tracks: [QobuzTrack]) -> NativeLibraryStatus? {
        guard let snapshot = archiveSnapshot else { return nil }
        let trackIDs = tracks.filter { $0.accountAvailabilityIssue == nil }.map(\.id)
        guard !trackIDs.isEmpty else { return nil }
        return NativeLibraryStatus(snapshot.coverage(trackIDs: trackIDs))
    }

    func browseCount(for category: NativeBrowseCategory) -> Int {
        browse.count(for: category)
    }

    func browseCountLabel(for category: NativeBrowseCategory) -> String {
        browse.countLabel(for: category)
    }

    func canLoadMoreBrowseResults(for category: NativeBrowseCategory) -> Bool {
        browse.canLoadMore(for: category)
    }

    func isLoadingMoreBrowseResults(for category: NativeBrowseCategory) -> Bool {
        browse.isLoadingMore(for: category)
    }

    func loadMoreBrowseResults(for category: NativeBrowseCategory) {
        browse.loadMore(for: category)
    }

    func downloadSelected() {
        guard let selectedQueueID else { return }
        startDownloads(ids: [selectedQueueID])
    }

    func downloadAll() {
        startDownloads(ids: queue.filter(isQueueItemStartable).map(\.id))
    }

    func downloadNext() {
        guard let next = queue.first(where: isQueueItemStartable) else { return }
        startDownloads(ids: [next.id])
    }

    func resume(_ activity: NativeDownloadActivity) {
        guard status(for: activity).canResume else { return }
        qobuzLog.notice(
            "activity.recovery",
            "User requested download resume",
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
        startDownloads(ids: [activity.queueID])
    }

    func retry(_ activity: NativeDownloadActivity) {
        guard status(for: activity).canRetry else { return }
        qobuzLog.notice(
            "activity.recovery",
            "User requested download retry",
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
        startDownloads(ids: [activity.queueID])
    }

    func canRestart(_ activity: NativeDownloadActivity) -> Bool {
        guard !isDownloading else { return false }
        return queue.first(where: { $0.id == activity.queueID }).map(isQueueItemStartable) == true
    }

    func canCancel(_ activity: NativeDownloadActivity) -> Bool {
        status(for: activity).isActive && activeItemQueueID == activity.queueID
    }

    func cancel(_ activity: NativeDownloadActivity) {
        guard canCancel(activity) else { return }
        qobuzLog.notice(
            "activity.recovery",
            "User requested item cancellation",
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
        activeItemDownloadTask?.cancel()
    }

    func removeActivity(_ activity: NativeDownloadActivity) {
        guard !status(for: activity).isActive else { return }
        activities.removeAll { $0.id == activity.id }
        let queueStillExists = queue.contains { $0.id == activity.queueID }
        updateDownloadState {
            $0.removeActivity(activity.id, queueStillExists: queueStillExists)
        }
        lastProgressUpdate.removeValue(forKey: activity.id)
        qobuzLog.info(
            "activity",
            "Activity item removed",
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
    }

    func resumablePartial(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        let status = status(for: activity)
        guard status.canResume || status.canRetry else { return nil }
        return partialArtifact(for: activity)
    }

    func repairArchiveTracks(_ tracks: [QobuzArchiveTrack]) {
        qobuzLog.notice(
            "library.repair",
            "Library repair requested",
            metadata: [
                "selectedCount": String(tracks.count),
                "problemCount": String(tracks.count { $0.integrity != .verified })
            ]
        )
        guard downloadTask == nil else {
            qobuzLog.warning("library.repair", "Library repair blocked by an active download")
            notice = "Wait for the current download to finish before starting repairs."
            return
        }
        guard credentials.isComplete else {
            qobuzLog.warning("library.repair", "Library repair blocked because credentials are not configured")
            notice = "Configure Qobuz credentials before repairing files."
            showSettings = true
            return
        }

        let unsupportedCount = tracks.count { track in
            track.integrity != .verified && track.audioFormat == nil
        }
        let ids = stageArchiveRepairs(tracks)
        qobuzLog.info(
            "library.repair",
            "Library repairs staged",
            metadata: ["stagedCount": String(ids.count), "unsupportedCount": String(unsupportedCount)]
        )

        guard !ids.isEmpty else {
            if unsupportedCount > 0 {
                notice = "The selected archive formats cannot be repaired automatically."
            }
            return
        }
        if unsupportedCount > 0 {
            notice = "Skipped \(unsupportedCount) unsupported archive format\(unsupportedCount == 1 ? "" : "s")."
        }
        startDownloads(ids: ids)
    }

    @discardableResult
    func stageArchiveRepairs(_ tracks: [QobuzArchiveTrack]) -> [UUID] {
        let repairable = tracks.filter {
            $0.integrity != .verified && $0.audioFormat != nil
        }
        var ids: [UUID] = []
        var seenPaths = Set<String>()
        for target in repairable where seenPaths.insert(target.relativePath).inserted {
            let request = QobuzRequest.track(QobuzID(target.qobuzTrackID))
            if let existing = queue.first(where: {
                $0.repairTarget?.relativePath == target.relativePath
                    || ($0.repairTarget == nil && $0.canonicalURL == request.canonicalURL)
            }) {
                guard !downloadState.status(forQueueID: existing.id).isActive else { continue }
                queueController.update(existing.id) { item in
                    item.repairTarget = target
                    item.title = URL(fileURLWithPath: target.relativePath).lastPathComponent
                    item.subtitle = "Repair · \(target.audioFormat?.displayName ?? "Format \(target.formatID)")"
                }
                transitionDownload(queueID: existing.id, to: .ready)
                ids.append(existing.id)
            } else {
                let item = NativeQueueItem(repairTarget: target)
                queueController.append(item)
                updateDownloadState { $0.registerQueue(item.id) }
                ids.append(item.id)
            }
        }
        return ids
    }

    func cancelDownloads() {
        qobuzLog.notice("download.batch", "User requested cancellation of the download batch")
        activeItemDownloadTask?.cancel()
        downloadTask?.cancel()
    }

    func clearFinishedActivities() {
        let removed = activities.filter { status(for: $0).isClearable }
        let removedIDs = Set(removed.map(\.id))
        activities.removeAll { removedIDs.contains($0.id) }
        let queueIDs = Set(queue.map(\.id))
        updateDownloadState { state in
            for activity in removed {
                state.removeActivity(
                    activity.id,
                    queueStillExists: queueIDs.contains(activity.queueID)
                )
            }
        }
        lastProgressUpdate = lastProgressUpdate.filter { !removedIDs.contains($0.key) }
        qobuzLog.info(
            "activity",
            "Finished activities and progress samples cleared",
            metadata: ["removedCount": String(removedIDs.count)]
        )
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        qobuzLog.notice(
            "lifecycle",
            "App termination preparation started",
            metadata: [
                "activeDownload": String(downloadTask != nil),
                "queueCount": String(queue.count),
                "activityCount": String(activities.count)
            ]
        )
        sessionPersistenceTask?.cancel()
        linkInboxController.cancel()
        previewController.cancel()
        connectivityMonitor.stop()
        markActiveDownloadsPaused(phase: "Paused after app closed")
        persistSessionNow(reportErrors: false)
        activeItemDownloadTask?.cancel()
        downloadTask?.cancel()
        qobuzLog.notice("lifecycle", "App termination state persisted")
    }

    func reveal(_ activity: NativeDownloadActivity) {
        let fileManager = FileManager.default
        let target: URL
        if let output = activity.outputURL, fileManager.fileExists(atPath: output.path) {
            target = output
        } else if let partial = partialArtifact(for: activity) {
            target = partial.url
        } else if let output = activity.outputURL,
                  fileManager.fileExists(atPath: output.deletingLastPathComponent().path) {
            target = output.deletingLastPathComponent()
        } else {
            target = URL(fileURLWithPath: settings.downloadPath, isDirectory: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func revealDownloadRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.downloadPath, isDirectory: true)])
    }

    private func partialArtifact(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        guard let output = activity.outputURL,
              let format = activity.audioFormat ?? activity.quality?.maximumFormat else { return nil }
        let url = QobuzDownloadArtifacts.partialURL(for: output, formatID: format.formatID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber,
              value.int64Value > 0 else { return nil }
        return NativePartialDownload(url: url, bytes: value.int64Value)
    }

    private func applyConfigurationChange(_ change: NativeConfigurationChange) {
        if change.downloadRootChanged {
            archiveTask?.cancel()
            archiveTask = nil
            archiveRefreshID = nil
            archiveSnapshot = nil
            isArchiveScanning = false
        }
        synchronizeBrowseAccount()
        showSettings = false
        Task { await testConnection(showSuccess: true) }
    }

    private func synchronizeBrowseAccount() {
        browse.configure(client: account.client, accountRegion: account.accountRegion)
        linkInboxController.configure(client: account.client, accountRegion: account.accountRegion)
    }

    private func applyConnectivityState(_ state: NativeConnectivityState) {
        guard connectivityState != state else { return }
        let previous = connectivityState
        connectivityState = state
        connectivityGeneration &+= 1
        connectivityEvents.publish(state: state, generation: connectivityGeneration)
        qobuzLog.notice(
            "network.path",
            "Network path state changed",
            metadata: [
                "previous": previous.rawValue,
                "current": state.rawValue,
                "generation": String(connectivityGeneration)
            ]
        )
    }

    private func waitForOnlineConnectivity(after generation: UInt64) async throws {
        qobuzLog.info(
            "download.recovery.network",
            "Waiting for a satisfied network path",
            metadata: [
                "connectivity": connectivityState.rawValue,
                "afterGeneration": String(generation)
            ]
        )
        try await connectivityEvents.waitForOnline(after: generation) { [weak self] in
            self?.connectivityState ?? .unknown
        }
    }

    private func loadArchiveCache() {
        let rootPath = URL(
            fileURLWithPath: settings.downloadPath,
            isDirectory: true
        ).standardizedFileURL.path
        do {
            if let cached = try archiveStore.load(), cached.rootPath == rootPath {
                archiveSnapshot = cached
                qobuzLog.debug(
                    "library.cache",
                    "Archive cache restored",
                    metadata: ["trackCount": String(cached.tracks.count), "problemCount": String(cached.problemCount)]
                )
            } else {
                archiveSnapshot = nil
                qobuzLog.debug("library.cache", "Archive cache did not match the current download root")
            }
        } catch {
            archiveSnapshot = nil
            qobuzLog.warning("library.cache", "Archive cache could not be restored", error: error)
        }
    }

    private func restoreSession() throws {
        guard var snapshot = try sessionStore.load() else { return }
        try snapshot.validate()
        restoringSession = true
        defer { restoringSession = false }

        downloadState = NativeDownloadStateStore(operations: snapshot.operations)
        let interruptedActivityIDs = downloadState.normalizeAfterInterruption()
        for index in snapshot.activities.indices
        where interruptedActivityIDs.contains(snapshot.activities[index].id) {
            snapshot.activities[index].phase = "Paused after interruption"
            snapshot.activities[index].bytesPerSecond = nil
        }
        activities = snapshot.activities
        linkInboxController.restore(snapshot.linkInbox)
        queueController.restore(items: snapshot.queue, selectedID: snapshot.selectedQueueID)
    }

    private func scheduleSessionPersistence() {
        guard started, !restoringSession, !isTerminating else { return }
        guard sessionPersistenceTask == nil else { return }
        sessionPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            sessionPersistenceTask = nil
            persistSessionNow()
        }
    }

    private func persistSessionNow(reportErrors: Bool = true) {
        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = nil
        do {
            try sessionStore.save(
                NativeSessionSnapshot(
                    queue: queue,
                    activities: activities,
                    operations: downloadState.operations,
                    selectedQueueID: selectedQueueID,
                    linkInbox: linkInbox
                )
            )
        } catch where reportErrors {
            qobuzLog.error("persistence.session", "Download session save failed", error: error)
            notice = "Could not save the download queue: \(error.localizedDescription)"
        } catch {
            qobuzLog.error("persistence.session", "Background download session save failed", error: error)
        }
    }

    private func loadPreview(_ item: NativeQueueItem) {
        previewController.load(
            item,
            client: client,
            onResolved: { [weak self] resolution in
                guard let self else { return }
                updateQueueMetadata(
                    resolution.queueID,
                    title: resolution.title,
                    subtitle: resolution.subtitle,
                    artworkURL: resolution.artworkURL
                )
                if let tracks = resolution.tracks {
                    updateQueueTrackPlan(resolution.queueID, tracks: tracks)
                }
            },
            onFailure: { [weak self] message in
                self?.transitionDownload(queueID: item.id, to: .failed(message))
            }
        )
    }

    private func startDownloads(ids: [UUID]) {
        guard downloadTask == nil, let client, credentials.isComplete else {
            qobuzLog.warning(
                "download.batch",
                "Download batch could not start",
                metadata: [
                    "activeBatch": String(downloadTask != nil),
                    "clientAvailable": String(client != nil),
                    "credentialsConfigured": String(credentials.isComplete)
                ]
            )
            if !credentials.isComplete { showSettings = true }
            return
        }
        let readyIDs = ids.filter { id in
            queue.first(where: { $0.id == id }).map(isQueueItemStartable) == true
        }
        guard !readyIDs.isEmpty else {
            qobuzLog.info(
                "download.batch",
                "Download batch had no startable queue items",
                metadata: ["requestedCount": String(ids.count)]
            )
            return
        }
        let defaultQuality = settings.quality
        let defaultRootPath = settings.downloadPath
        let batchID = UUID().uuidString
        let batchStarted = Date()
        qobuzLog.notice(
            "download.batch",
            "Download batch started",
            metadata: [
                "downloadBatchID": batchID,
                "requestedCount": String(ids.count),
                "readyCount": String(readyIDs.count)
            ]
        )

        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                activeItemDownloadTask?.cancel()
                activeItemDownloadTask = nil
                activeItemQueueID = nil
                downloadTask = nil
                if !isTerminating { refreshArchive() }
            }
            do {
                let validator = try FFmpegMediaValidator.bundled()
                let engine = NativeQobuzDownloadEngine(
                    service: client,
                    validator: validator,
                    reusableAudioIndex: reusableAudioIndex
                )
                for id in readyIDs {
                    try Task.checkCancellation()
                    guard let item = queue.first(where: { $0.id == id }) else { continue }
                    let quality = item.downloadQuality ?? defaultQuality
                    let root = URL(
                        fileURLWithPath: item.downloadRootPath ?? defaultRootPath,
                        isDirectory: true
                    )
                    let itemTask = Task { [weak self] in
                        guard let self else { return }
                        await QobuzLogScope.withValue(["downloadBatchID": batchID]) {
                            await self.runDownload(id: id, engine: engine, quality: quality, root: root)
                        }
                    }
                    activeItemDownloadTask = itemTask
                    activeItemQueueID = id
                    await itemTask.value
                    if activeItemQueueID == id {
                        activeItemDownloadTask = nil
                        activeItemQueueID = nil
                    }
                }
                qobuzLog.notice(
                    "download.batch",
                    "Download batch finished",
                    metadata: [
                        "downloadBatchID": batchID,
                        "durationMs": String(Int(Date().timeIntervalSince(batchStarted) * 1_000))
                    ]
                )
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice("download.batch", "Download batch cancelled", metadata: ["downloadBatchID": batchID])
                if isTerminating { markActiveDownloadsPaused(phase: "Paused after app closed") }
                else { markActiveDownloadsCancelled() }
            } catch {
                qobuzLog.error(
                    "download.batch",
                    "Download batch failed before an item could finish",
                    metadata: ["downloadBatchID": batchID],
                    error: error
                )
                notice = error.localizedDescription
            }
        }
    }

    private func runDownload(
        id queueID: UUID,
        engine: NativeQobuzDownloadEngine,
        quality: QobuzQuality,
        root: URL
    ) async {
        guard let item = queue.first(where: { $0.id == queueID }) else { return }
        let repairFormat = item.repairTarget?.audioFormat
        updateQueue(queueID) {
            if $0.repairTarget == nil { $0.downloadQuality = quality }
            $0.downloadRootPath = root.standardizedFileURL.path
        }
        let activityID: UUID
        if let index = activities.firstIndex(where: {
            guard $0.queueID == queueID else { return false }
            let status = status(for: $0)
            return status.canResume || status.canRetry
        }) {
            activityID = activities[index].id
            let partial = resumablePartial(for: activities[index])
            let isRetry = status(for: activities[index]).canRetry
            activities[index].phase = partial == nil
                ? (isRetry ? "Retrying" : "Resuming")
                : "Resuming existing partial file"
            activities[index].quality = repairFormat == nil ? quality : nil
            activities[index].audioFormat = repairFormat
            activities[index].bytesPerSecond = nil
            activities[index].errorMessage = nil
        } else {
            activityID = UUID()
            activities.insert(
                NativeDownloadActivity(
                    id: activityID,
                    queueID: queueID,
                    title: item.title,
                    quality: repairFormat == nil ? quality : nil,
                    audioFormat: repairFormat
                ),
                at: 0
            )
        }
        transitionDownload(queueID: queueID, activityID: activityID, to: .queued)
        let operationMetadata = [
            "queueID": queueID.uuidString,
            "activityID": activityID.uuidString,
            "requestKind": item.request.kindName,
            "qobuzID": item.request.id.rawValue,
            "qualityPolicy": repairFormat == nil ? quality.rawValue : "exact-archive-repair",
            "requestedFormatID": String((repairFormat ?? quality.maximumFormat).formatID),
            "downloadRoot": root.standardizedFileURL.path,
            "repair": String(item.repairTarget != nil),
            "selectedTrackCount": item.selectedTrackIDs.map { String($0.count) } ?? "all"
        ]
        let itemStarted = Date()
        qobuzLog.notice(
            "download.item",
            "Queue item download started",
            metadata: operationMetadata.merging([
                "partialResumeBytes": activities.first(where: { $0.id == activityID })
                    .flatMap(resumablePartial(for:))
                    .map { String($0.bytes) } ?? "0"
            ]) { _, new in new }
        )
        persistSessionNow(reportErrors: false)
        await QobuzLogScope.withValue(operationMetadata) {
            var connectivityRecovery = NativeConnectivityRecoveryPolicy()
            var refreshedExpiredURL = false
            while !Task.isCancelled {
                do {
                    try await withNativePowerActivity(
                        using: powerActivityManager,
                        reason: "Downloading \(item.title)"
                    ) {
                        let events = if let repairTarget = item.repairTarget {
                            try engine.repairEvents(for: repairTarget, downloadRoot: root)
                        } else {
                            engine.events(
                                for: item.request,
                                quality: quality,
                                downloadRoot: root,
                                includedTrackIDs: item.selectedTrackIDs
                            )
                        }
                        for try await event in events {
                            try Task.checkCancellation()
                            reduce(event, activityID: activityID)
                        }
                    }
                    transitionDownload(queueID: queueID, activityID: activityID, to: .completed)
                    qobuzLog.notice(
                        "download.item",
                        "Queue item download completed",
                        metadata: ["durationMs": String(Int(Date().timeIntervalSince(itemStarted) * 1_000))]
                    )
                    return
                } catch let error where error.isQobuzCancellation {
                    finishCancelledDownload(queueID: queueID, activityID: activityID, startedAt: itemStarted)
                    return
                } catch let error as NativeQobuzError where error.requiresFreshSignedURL && !refreshedExpiredURL {
                    refreshedExpiredURL = true
                    let partialExists = activities.first(where: { $0.id == activityID })
                        .flatMap(resumablePartial(for:)) != nil
                    qobuzLog.warning(
                        "download.recovery.url",
                        "Expired audio URL detected; reacquiring a fresh signed Qobuz URL",
                        metadata: ["partialPreserved": String(partialExists)],
                        error: error
                    )
                    transitionDownload(queueID: queueID, activityID: activityID, to: .queued)
                    updateActivity(activityID) {
                        $0.phase = "Refreshing expired Qobuz link"
                        $0.errorMessage = nil
                        $0.bytesPerSecond = nil
                    }
                    persistSessionNow(reportErrors: false)
                    continue
                } catch let error as NativeQobuzError where error.isConnectivityLoss {
                    let generationAtFailure = connectivityGeneration
                    let partial = activities.first(where: { $0.id == activityID }).flatMap(resumablePartial(for:))
                    qobuzLog.warning(
                        "download.recovery.network",
                        "Queue item is waiting for network recovery",
                        metadata: [
                            "connectivity": connectivityState.rawValue,
                            "connectivityGeneration": String(generationAtFailure),
                            "partialPath": partial?.url.path ?? "none",
                            "partialBytes": partial.map { String($0.bytes) } ?? "0"
                        ],
                        error: error
                    )
                    transitionDownload(queueID: queueID, activityID: activityID, to: .waitingForNetwork)
                    updateActivity(activityID) {
                        $0.phase = partial == nil
                            ? "Waiting for network · resumes automatically"
                            : "Waiting for network · partial file preserved"
                        $0.errorMessage = nil
                        $0.bytesPerSecond = nil
                    }
                    persistSessionNow(reportErrors: false)

                    switch connectivityRecovery.action(
                        state: connectivityState,
                        generation: generationAtFailure
                    ) {
                    case .retryNow:
                        qobuzLog.info(
                            "download.recovery.network",
                            "System path is online; refreshing the signed URL once",
                            metadata: ["connectivityGeneration": String(generationAtFailure)]
                        )
                    case .waitForChange(let generation):
                        do {
                            try await waitForOnlineConnectivity(after: generation)
                        } catch {
                            finishCancelledDownload(queueID: queueID, activityID: activityID, startedAt: itemStarted)
                            return
                        }
                        connectivityRecovery.recovered()
                        refreshedExpiredURL = false
                        qobuzLog.notice(
                            "download.recovery.network",
                            "Network path recovered; resuming with a fresh signed URL",
                            metadata: ["connectivityGeneration": String(connectivityGeneration)]
                        )
                    }
                    transitionDownload(queueID: queueID, activityID: activityID, to: .queued)
                    updateActivity(activityID) {
                        $0.phase = "Network restored · refreshing Qobuz link"
                        $0.errorMessage = nil
                    }
                    continue
                } catch let error as NativeQobuzError where error.canResumeTransfer {
                    qobuzLog.warning(
                        "download.item",
                        "Queue item download paused after a resumable failure",
                        metadata: [
                            "durationMs": String(Int(Date().timeIntervalSince(itemStarted) * 1_000)),
                            "partialPath": activities.first(where: { $0.id == activityID })
                                .flatMap(resumablePartial(for:))?.url.path ?? "none"
                        ],
                        error: error
                    )
                    transitionDownload(queueID: queueID, activityID: activityID, to: .paused)
                    updateActivity(activityID) {
                        $0.phase = "Paused · \(error.localizedDescription)"
                        $0.errorMessage = error.localizedDescription
                        $0.bytesPerSecond = nil
                    }
                    return
                } catch {
                    qobuzLog.error(
                        "download.item",
                        "Queue item download failed",
                        metadata: ["durationMs": String(Int(Date().timeIntervalSince(itemStarted) * 1_000))],
                        error: error
                    )
                    transitionDownload(
                        queueID: queueID,
                        activityID: activityID,
                        to: .failed(error.localizedDescription)
                    )
                    updateActivity(activityID) {
                        $0.phase = error.localizedDescription
                        $0.errorMessage = error.localizedDescription
                        $0.bytesPerSecond = nil
                    }
                    return
                }
            }
            finishCancelledDownload(queueID: queueID, activityID: activityID, startedAt: itemStarted)
        }
    }

    private func finishCancelledDownload(queueID: UUID, activityID: UUID, startedAt: Date) {
        qobuzLog.notice(
            "download.item",
            isTerminating ? "Queue item paused for app termination" : "Queue item download cancelled",
            metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))]
        )
        if isTerminating {
            transitionDownload(queueID: queueID, activityID: activityID, to: .paused)
            updateActivity(activityID) {
                $0.phase = "Paused after app closed"
                $0.bytesPerSecond = nil
            }
        } else {
            transitionDownload(queueID: queueID, activityID: activityID, to: .cancelled)
            updateActivity(activityID) {
                $0.phase = "Cancelled"
                $0.errorMessage = nil
                $0.bytesPerSecond = nil
            }
        }
    }

    private func reduce(_ event: QobuzDownloadEvent, activityID: UUID) {
        // Progress arrives many times a second; repainting the caption that
        // often makes it jitter. 5 Hz is plenty. Track-completion progress
        // (fraction == 1) always applies so counts and sizes end exact.
        if case .progress(let progress) = event, (progress.currentTrackFraction ?? 1) < 1 {
            let now = Date()
            if let last = lastProgressUpdate[activityID], now.timeIntervalSince(last) < 0.2 { return }
            lastProgressUpdate[activityID] = now
        } else {
            lastProgressUpdate[activityID] = nil
        }
        let queueID = activities.first(where: { $0.id == activityID })?.queueID
        let status: NativeDownloadStatus? = switch event {
        case .resolving: .resolving
        case .trackStarted, .progress: .downloading
        case .tagging: .tagging
        case .validating: .validating
        case .completed: .completed
        default: nil
        }
        if let queueID, let status {
            transitionDownload(queueID: queueID, activityID: activityID, to: status)
        }
        updateActivity(activityID) { activity in
            switch event {
            case .resolving:
                activity.phase = "Resolving Qobuz"
            case .planReady(let title, let count):
                activity.title = title
                activity.totalTracks = count
                activity.phase = "Preparing media"
            case .trackStarted(let track, let destination, let format):
                activity.phase = "Downloading"
                activity.currentTrack = track.track.displayTitle
                activity.outputURL = destination
                activity.audioFormat = format
                activity.bytesPerSecond = nil
            case .progress(let progress):
                activity.progress = progress.overallFraction
                activity.completedTracks = progress.completedTracks
                activity.totalTracks = progress.totalTracks
                // Keep the last known values when a sample is missing (each
                // track restarts measurement) so the caption stays steady.
                if let written = progress.bytesWritten { activity.bytesWritten = written }
                if let total = progress.totalBytes { activity.totalBytes = total }
                if let speed = progress.bytesPerSecond { activity.bytesPerSecond = speed }
                if let album = progress.albumBytesWritten { activity.albumBytesWritten = album }
            case .tagging:
                activity.phase = "Writing metadata"
            case .validating:
                activity.phase = "Checking audio integrity"
            case .integrityVerified(_, let checksum):
                activity.checksum = checksum
                activity.phase = "Integrity verified"
            case .assetCreated(let url):
                activity.phase = "Created \(url.lastPathComponent)"
            case .notice(let message):
                if !activity.notices.contains(message) { activity.notices.append(message) }
            case .warning(let message):
                if !activity.warnings.contains(message) { activity.warnings.append(message) }
                activity.phase = "Finishing with warnings"
            case .trackCompleted(_, let destination), .trackSkipped(_, let destination):
                activity.outputURL = destination
            case .completed:
                activity.phase = activity.warnings.isEmpty ? "Complete" : "Complete with warnings"
                activity.progress = 1
                activity.bytesPerSecond = nil
            }
        }
    }

    private func markActiveDownloadsCancelled() {
        let active = activities.filter { status(for: $0).isActive }.map { ($0.queueID, $0.id) }
        for (queueID, activityID) in active {
            transitionDownload(queueID: queueID, activityID: activityID, to: .cancelled)
            guard let index = activities.firstIndex(where: { $0.id == activityID }) else { continue }
            activities[index].phase = "Cancelled"
        }
    }

    private func markActiveDownloadsPaused(phase: String) {
        let active = activities.filter { status(for: $0).isActive }.map { ($0.queueID, $0.id) }
        for (queueID, activityID) in active {
            transitionDownload(queueID: queueID, activityID: activityID, to: .paused)
            guard let index = activities.firstIndex(where: { $0.id == activityID }) else { continue }
            activities[index].phase = phase
            activities[index].bytesPerSecond = nil
        }
    }

    private func transitionDownload(
        queueID: UUID,
        activityID: UUID? = nil,
        to status: NativeDownloadStatus
    ) {
        let previous = downloadState.operation(forQueueID: queueID)
        updateDownloadState {
            $0.transition(queueID: queueID, activityID: activityID, to: status)
        }
        guard previous?.status != status || (activityID != nil && previous?.activityID != activityID) else {
            return
        }
        qobuzLog.debug(
            "download.lifecycle",
            "Download operation transitioned",
            metadata: [
                "queueID": queueID.uuidString,
                "activityID": activityID?.uuidString ?? previous?.activityID?.uuidString ?? "none",
                "from": previous?.status.diagnosticDescription ?? "unregistered",
                "to": status.diagnosticDescription
            ]
        )
    }

    private func updateDownloadState(
        _ mutate: (inout NativeDownloadStateStore) -> Void
    ) {
        var updated = downloadState
        mutate(&updated)
        guard updated != downloadState else { return }
        objectWillChange.send()
        downloadState = updated
        scheduleSessionPersistence()
    }

    private func updateQueue(_ id: UUID, mutate: (inout NativeQueueItem) -> Void) {
        queueController.update(id, mutate: mutate)
    }

    private func isQueueItemStartable(_ item: NativeQueueItem) -> Bool {
        status(for: item).canStart && item.hasSelectedTracks
    }

    private func resetQueueStatusAfterPlanChange(_ queueID: UUID) {
        switch downloadState.status(forQueueID: queueID) {
        case .queued, .resolving, .downloading, .tagging, .validating, .waitingForNetwork:
            break
        case .ready:
            break
        case .paused, .completed, .failed, .cancelled:
            transitionDownload(queueID: queueID, to: .ready)
        }
    }

    private func updateQueueTrackPlan(_ id: UUID, tracks: [QobuzTrack]) {
        queueController.updateTrackPlan(id, tracks: tracks) { [weak self] track in
            self?.unavailabilityMessage(for: track)
        }
    }

    private func updateQueueMetadata(_ id: UUID, title: String, subtitle: String, artworkURL: URL? = nil) {
        queueController.updateMetadata(id, title: title, subtitle: subtitle, artworkURL: artworkURL)
    }

    private func updateActivity(_ id: UUID, mutate: (inout NativeDownloadActivity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        mutate(&activities[index])
    }

    private func makeDiagnosticReport() -> NativeDiagnosticReport {
        let architecture: String
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "unknown"
        #endif
        let bundle = Bundle.main
        return NativeDiagnosticReport(
            generatedAt: Date(),
            diagnosticSessionID: QobuzDiagnostics.shared.sessionID,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            downloadQuality: settings.quality.displayName,
            downloadRoot: settings.downloadPath,
            queue: queue.map { item in
                NativeDiagnosticQueueSummary(
                    id: item.id,
                    request: "\(item.request.kindName):\(item.request.id.rawValue)",
                    title: item.title,
                    status: status(for: item).diagnosticDescription,
                    selectedTracks: queuePreflight(for: item).selected,
                    quality: item.downloadQuality?.displayName
                )
            },
            activities: activities.map { activity in
                NativeDiagnosticActivitySummary(
                    id: activity.id,
                    queueID: activity.queueID,
                    title: activity.title,
                    status: status(for: activity).diagnosticDescription,
                    phase: activity.phase,
                    progress: activity.progress,
                    outputPath: activity.outputURL?.path,
                    warnings: activity.warnings,
                    error: activity.errorMessage
                )
            },
            libraryTrackCount: archiveSnapshot?.tracks.count ?? 0,
            libraryIssueCount: archiveSnapshot?.issues.count ?? 0,
            credentialsConfigured: credentials.isComplete
        )
    }

}
