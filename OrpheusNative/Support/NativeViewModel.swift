import AppKit
import Combine
import Foundation
import NativeQobuzCore

@MainActor
final class NativeViewModel: ObservableObject {
    @Published var input = ""
    @Published var notice: String?
    @Published var showSettings = false
    @Published var showDiagnostics = false

    private let sessionStore: any NativeSessionStoring
    private let diagnostics: NativeDiagnosticsController
    private let account: NativeAccountController
    private let browse = NativeBrowseController()
    private let queueController: NativeQueueController
    private let previewController = NativePreviewController()
    private let linkInboxController = NativeLinkInboxController()
    private let library: NativeLibraryController
    private let connectivity: NativeConnectivityController
    private let downloads: NativeDownloadController
    private var sessionPersistenceTask: Task<Void, Never>?
    private var started = false
    private var restoringSession = false
    private var isTerminating = false
    private var accountObservation: AnyCancellable?
    private var browseObservation: AnyCancellable?
    private var queueObservation: AnyCancellable?
    private var previewObservation: AnyCancellable?
    private var linkInboxObservation: AnyCancellable?
    private var libraryObservation: AnyCancellable?
    private var connectivityObservation: AnyCancellable?
    private var downloadsObservation: AnyCancellable?

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
        let queueController = NativeQueueController()
        let connectivity = NativeConnectivityController(
            monitor: connectivityMonitor ?? NativeNetworkConnectivityMonitor()
        )
        account = NativeAccountController(
            paths: paths,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            clientFactory: clientFactory
        )
        library = NativeLibraryController(
            archiveStore: archiveStore ?? NativeArchiveIndexStore(paths: paths),
            scanner: archiveScanner,
            adopter: libraryAdopter ?? QobuzLibraryAdopter(scanner: archiveScanner)
        )
        self.queueController = queueController
        self.connectivity = connectivity
        downloads = NativeDownloadController(
            queue: queueController,
            connectivity: connectivity,
            powerActivityManager: powerActivityManager ?? NativePowerActivityManager()
        )
        self.sessionStore = sessionStore ?? NativeSessionStore(paths: paths)
        diagnostics = NativeDiagnosticsController(
            logStore: logStore ?? NativeLogFileStore(paths: paths),
            supplementalCollector: supplementalDiagnosticsCollector ?? NativeSupplementalDiagnosticsCollector()
        )
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
        libraryObservation = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        connectivityObservation = connectivity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        downloadsObservation = downloads.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleSessionPersistence()
        }
        downloads.configureCallbacks(
            onNotice: { [weak self] message in self?.notice = message },
            onRequireSettings: { [weak self] in self?.showSettings = true },
            onArchiveRefresh: { [weak self] in self?.refreshArchive() },
            onCheckpoint: { [weak self] in self?.persistSessionNow(reportErrors: false) }
        )
        do {
            try diagnostics.activate()
            qobuzLog.info("lifecycle", "Native view model initialized")
        } catch {
            FileHandle.standardError.write(Data("Could not activate diagnostics: \(error.localizedDescription)\n".utf8))
        }
    }

    var queue: [NativeQueueItem] { queueController.items }
    var activities: [NativeDownloadActivity] { downloads.activities }
    var connectivityState: NativeConnectivityState { connectivity.state }
    var selectedQueueID: UUID? { queueController.selectedID }
    var selectedQueueItem: NativeQueueItem? { queueController.selectedItem }
    var preview: NativePreviewState { previewController.state }
    var linkInbox: [NativeLinkInboxItem] { linkInboxController.items }
    var isLibraryOpen: Bool { library.isOpen }
    var archiveSnapshot: QobuzArchiveSnapshot? { library.snapshot }
    var isArchiveScanning: Bool { library.isScanning }
    private var libraryRoot: URL {
        URL(fileURLWithPath: settings.downloadPath, isDirectory: true).standardizedFileURL
    }

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
            && selectedQueueItem.map { downloads.isStartable($0) } == true
            && credentials.isComplete
    }

    var canDownloadAll: Bool {
        !isDownloading && credentials.isComplete && queue.contains { downloads.isStartable($0) }
    }

    var canDownloadNext: Bool { canDownloadAll }

    var isDownloading: Bool { downloads.isDownloading }
    var canCancel: Bool { downloads.isDownloading }
    var canClearActivity: Bool { downloads.canClearActivity }
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
        downloads.status(for: item)
    }

    func status(for activity: NativeDownloadActivity) -> NativeDownloadStatus {
        downloads.status(for: activity)
    }

    func detailError(for activity: NativeDownloadActivity) -> String? {
        downloads.detailError(for: activity)
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
        try await diagnostics.export(snapshot: makeDiagnosticSnapshot(), to: parent)
    }

    func start() {
        guard !started else {
            qobuzLog.debug("lifecycle", "Ignored duplicate app startup request")
            return
        }
        started = true
        connectivity.start()
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
            library.loadCache(for: libraryRoot)
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
        downloads.registerQueue(item.id)
        loadPreview(item)
    }

    func addAlbums(_ albums: [QobuzAlbum]) {
        let result = queueController.addAlbums(albums)
        guard !result.added.isEmpty else {
            if result.skipped > 0 { notice = "Those editions are already queued." }
            return
        }
        downloads.registerQueues(result.added.map(\.id))
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
            isActive: downloads.status(forQueueID: id).isActive
        )
        guard result.removedID != nil else { return }
        downloads.removeQueue(id)
        if let selectedItem = result.selectedItem { loadPreview(selectedItem) }
        else { previewController.clear() }
    }

    func clearQueue() {
        let activeIDs = Set(queue.filter { status(for: $0).isActive }.map(\.id))
        let result = queueController.clear(retaining: activeIDs)
        for id in result.removedIDs { downloads.removeQueue(id) }
        if let selectedItem = result.selectedItem { loadPreview(selectedItem) }
        else { previewController.clear() }
    }

    func setQueueQuality(_ quality: QobuzQuality?, for id: UUID) {
        guard queueController.setQuality(quality, for: id, mutationsAllowed: !isDownloading) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func toggleQueueTrack(_ trackID: QobuzID, in id: UUID) {
        guard queueController.toggleTrack(trackID, in: id, mutationsAllowed: !isDownloading) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func selectAllQueueTracks(in id: UUID) {
        guard queueController.selectAllTracks(in: id, mutationsAllowed: !isDownloading) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func clearQueueTrackSelection(in id: UUID) {
        guard queueController.clearTrackSelection(in: id, mutationsAllowed: !isDownloading) else { return }
        downloads.resetAfterPlanChange(id)
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
        library.close()
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
        library.close()
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
        library.close()
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
        library.open(root: libraryRoot) { [weak self] message in self?.notice = message }
    }

    func closeLibrary() {
        library.close()
    }

    func refreshArchive(fullVerification: Bool = false) {
        library.refresh(
            root: libraryRoot,
            fullVerification: fullVerification,
            onFailure: { [weak self] message in self?.notice = message }
        )
    }

    func inspectLibraryForAdoption(at root: URL) async throws -> QobuzLibraryAdoptionPlan {
        try await library.inspectForAdoption(at: root, downloadIsActive: isDownloading)
    }

    func adoptLibrary(at root: URL, draft: SettingsDraft) async throws {
        let pending = try await library.prepareAdoption(at: root, downloadIsActive: isDownloading)
        do {
            try saveConfiguration(
                credentials: draft.credentials,
                settings: NativeSettings(
                    downloadPath: pending.result.plan.root.path,
                    quality: draft.quality
                )
            )
            try library.activate(pending)
            browse.close()
            showSettings = false
            let repaired = pending.result.plan.manifestAction != .none
            notice = repaired
                ? "Existing Library adopted and its index was rebuilt."
                : "Existing Library adopted and verified."
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                "Adopted Library could not become the active download root",
                metadata: ["libraryAdoptionID": pending.id, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func revealArchiveTrack(_ track: QobuzArchiveTrack) {
        library.revealTrack(track)
    }

    func revealArchiveEntry(_ entry: QobuzArchiveEntry) {
        library.revealEntry(entry)
    }

    func revealArchiveIssue(_ issue: NativeLibraryIndexProblem) {
        library.revealIssue(issue)
    }

    func libraryStatus(for item: NativeQueueItem) -> NativeLibraryStatus? {
        library.status(for: item)
    }

    func libraryStatus(for album: QobuzAlbumSummary) -> NativeLibraryStatus? {
        library.status(for: album)
    }

    func libraryStatus(for album: QobuzAlbum) -> NativeLibraryStatus? {
        library.status(for: album)
    }

    func libraryStatus(for track: QobuzTrack) -> NativeLibraryStatus? {
        library.status(for: track)
    }

    func libraryStatus(for tracks: [QobuzTrack]) -> NativeLibraryStatus? {
        library.status(for: tracks)
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
        startDownloads(ids: queue.filter { downloads.isStartable($0) }.map(\.id))
    }

    func downloadNext() {
        guard let next = queue.first(where: { downloads.isStartable($0) }) else { return }
        startDownloads(ids: [next.id])
    }

    func resume(_ activity: NativeDownloadActivity) {
        downloads.resume(
            activity,
            client: client,
            credentialsConfigured: credentials.isComplete,
            defaultQuality: settings.quality,
            defaultRootPath: settings.downloadPath
        )
    }

    func retry(_ activity: NativeDownloadActivity) {
        downloads.retry(
            activity,
            client: client,
            credentialsConfigured: credentials.isComplete,
            defaultQuality: settings.quality,
            defaultRootPath: settings.downloadPath
        )
    }

    func canRestart(_ activity: NativeDownloadActivity) -> Bool {
        downloads.canRestart(activity)
    }

    func canCancel(_ activity: NativeDownloadActivity) -> Bool {
        downloads.canCancel(activity)
    }

    func cancel(_ activity: NativeDownloadActivity) {
        downloads.cancel(activity)
    }

    func removeActivity(_ activity: NativeDownloadActivity) {
        downloads.removeActivity(activity)
    }

    func resumablePartial(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        downloads.resumablePartial(for: activity)
    }

    func repairArchiveTracks(_ tracks: [QobuzArchiveTrack]) {
        downloads.repairArchiveTracks(
            tracks,
            client: client,
            credentialsConfigured: credentials.isComplete,
            defaultQuality: settings.quality,
            defaultRootPath: settings.downloadPath
        )
    }

    @discardableResult
    func stageArchiveRepairs(_ tracks: [QobuzArchiveTrack]) -> [UUID] {
        downloads.stageArchiveRepairs(tracks)
    }

    func cancelDownloads() {
        downloads.cancelAll()
    }

    func clearFinishedActivities() {
        downloads.clearFinishedActivities()
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        qobuzLog.notice(
            "lifecycle",
            "App termination preparation started",
            metadata: [
                "activeDownload": String(downloads.isDownloading),
                "queueCount": String(queue.count),
                "activityCount": String(activities.count)
            ]
        )
        sessionPersistenceTask?.cancel()
        linkInboxController.cancel()
        previewController.cancel()
        library.cancelRefresh()
        connectivity.stop()
        downloads.prepareForTermination()
        persistSessionNow(reportErrors: false)
        qobuzLog.notice("lifecycle", "App termination state persisted")
    }

    func reveal(_ activity: NativeDownloadActivity) {
        downloads.reveal(activity, defaultRootPath: settings.downloadPath)
    }

    func revealDownloadRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.downloadPath, isDirectory: true)])
    }

    private func applyConfigurationChange(_ change: NativeConfigurationChange) {
        if change.downloadRootChanged {
            library.invalidate()
        }
        synchronizeBrowseAccount()
        showSettings = false
        Task { await testConnection(showSuccess: true) }
    }

    private func synchronizeBrowseAccount() {
        browse.configure(client: account.client, accountRegion: account.accountRegion)
        linkInboxController.configure(client: account.client, accountRegion: account.accountRegion)
    }

    private func restoreSession() throws {
        guard let snapshot = try sessionStore.load() else { return }
        try snapshot.validate()
        restoringSession = true
        defer { restoringSession = false }

        downloads.restore(activities: snapshot.activities, operations: snapshot.operations)
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
                    operations: downloads.operations,
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
                self?.downloads.markFailed(queueID: item.id, message: message)
            }
        )
    }

    private func startDownloads(ids: [UUID]) {
        downloads.start(
            ids: ids,
            client: client,
            credentialsConfigured: credentials.isComplete,
            defaultQuality: settings.quality,
            defaultRootPath: settings.downloadPath
        )
    }

    private func updateQueueTrackPlan(_ id: UUID, tracks: [QobuzTrack]) {
        queueController.updateTrackPlan(id, tracks: tracks) { [weak self] track in
            self?.unavailabilityMessage(for: track)
        }
    }

    private func updateQueueMetadata(_ id: UUID, title: String, subtitle: String, artworkURL: URL? = nil) {
        queueController.updateMetadata(id, title: title, subtitle: subtitle, artworkURL: artworkURL)
    }

    private func makeDiagnosticSnapshot() -> NativeDiagnosticSnapshot {
        NativeDiagnosticSnapshot(
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
