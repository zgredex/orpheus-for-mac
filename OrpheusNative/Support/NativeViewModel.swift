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

    let diagnostics: NativeDiagnosticsController
    let account: NativeAccountController
    let browse: NativeBrowseController
    let queueController: NativeQueueController
    let previewController: NativePreviewController
    let linkInboxController: NativeLinkInboxController
    let library: NativeLibraryController
    let libraryManagement: NativeLibraryManagementController
    let connectivity: NativeConnectivityController
    let downloads: NativeDownloadController
    private let downloadOrchestrator: NativeDownloadOrchestrator
    private let queueOrchestrator: NativeQueueOrchestrator
    private let browseNavigation: NativeBrowseNavigationController
    private let session: NativeSessionController
    private let lifecycle: NativeAppLifecycleController
    private let requestIntake: NativeRequestIntakeController
    private let diagnosticSnapshotBuilder: NativeDiagnosticSnapshotBuilder
    private let libraryAdoption: NativeLibraryAdoptionCoordinator
    private let configurationMutations: NativeConfigurationMutationCoordinator
    private var sessionObservationRelay: NativeSessionObservationRelay?
    private var startupObservation: AnyCancellable?

    init(
        paths: NativePaths,
        configurationStore: (any NativeConfigurationStoring)? = nil,
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
        let browse = NativeBrowseController()
        let queueController = NativeQueueController()
        let previewController = NativePreviewController()
        let linkInboxController = NativeLinkInboxController()
        let connectivity = NativeConnectivityController(
            monitor: connectivityMonitor ?? NativeNetworkConnectivityMonitor()
        )
        let account = NativeAccountController(
            paths: paths,
            configurationStore: configurationStore,
            clientFactory: clientFactory
        )
        let library = NativeLibraryController(
            archiveStore: archiveStore ?? NativeArchiveIndexStore(paths: paths),
            scanner: archiveScanner,
            adopter: libraryAdopter ?? QobuzLibraryAdopter(scanner: archiveScanner)
        )
        let downloads = NativeDownloadController(
            queue: queueController,
            connectivity: connectivity,
            powerActivityManager: powerActivityManager ?? NativePowerActivityManager()
        )
        let libraryManagement = NativeLibraryManagementController(
            account: account,
            library: library,
            downloads: downloads,
            maintenance: QobuzLibraryMaintenanceService(scanner: archiveScanner)
        )
        let session = NativeSessionController(
            store: sessionStore ?? NativeSessionStore(paths: paths),
            queue: queueController,
            downloads: downloads,
            linkInbox: linkInboxController
        )
        self.account = account
        self.browse = browse
        self.queueController = queueController
        self.previewController = previewController
        self.linkInboxController = linkInboxController
        self.library = library
        self.libraryManagement = libraryManagement
        self.connectivity = connectivity
        self.downloads = downloads
        libraryAdoption = NativeLibraryAdoptionCoordinator(
            account: account,
            library: library
        )
        downloadOrchestrator = NativeDownloadOrchestrator(
            account: account,
            queue: queueController,
            downloads: downloads,
            libraryManagement: libraryManagement
        )
        queueOrchestrator = NativeQueueOrchestrator(
            queue: queueController,
            preview: previewController,
            downloads: downloads
        )
        browseNavigation = NativeBrowseNavigationController(browse: browse, library: library)
        self.session = session
        let lifecycle = NativeAppLifecycleController(
            account: account,
            browse: browse,
            queue: queueController,
            preview: previewController,
            linkInbox: linkInboxController,
            library: library,
            connectivity: connectivity,
            downloads: downloads,
            session: session,
            queueOrchestrator: queueOrchestrator
        )
        self.lifecycle = lifecycle
        configurationMutations = NativeConfigurationMutationCoordinator(
            account: account,
            downloads: downloads,
            libraryManagement: libraryManagement,
            library: library,
            requirePermission: lifecycle.requireConfigurationMutationPermission
        )
        requestIntake = NativeRequestIntakeController(linkInbox: linkInboxController)
        diagnosticSnapshotBuilder = NativeDiagnosticSnapshotBuilder(
            account: account,
            queue: queueController,
            downloads: downloads,
            library: library
        )
        diagnostics = NativeDiagnosticsController(
            logStore: logStore ?? NativeLogFileStore(paths: paths),
            supplementalCollector: supplementalDiagnosticsCollector ?? NativeSupplementalDiagnosticsCollector()
        )
        let sessionObservationRelay = NativeSessionObservationRelay(
            onPersistenceChange: { [weak self] in self?.session.schedulePersistence() }
        )
        sessionObservationRelay.observe(queueController)
        sessionObservationRelay.observe(linkInboxController)
        sessionObservationRelay.observe(downloads)
        self.sessionObservationRelay = sessionObservationRelay
        startupObservation = lifecycle.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        session.configure { [weak self] message in self?.notice = message }
        browseNavigation.configure { [weak self] message in
            self?.notice = message
            self?.showSettings = true
        }
        downloads.configureCallbacks(
            onNotice: { [weak self] message in self?.notice = message },
            onRequireSettings: { [weak self] in self?.showSettings = true },
            onIndexLibrary: { root, changedAudioURLs in
                try await library.indexDownloadedRoot(root, changedAudioURLs: changedAudioURLs, activeRoot: account.downloadRoot)
            },
            onCheckpoint: { [weak self] in self?.session.persistCheckpoint() },
            currentLibrarySnapshot: { library.snapshot },
            recoveryCleanupAllowed: { [weak libraryManagement, weak library] in
                libraryManagement?.isWorking != true
                    && library?.isScanning != true
                    && library?.isPerformingAdoption != true
            }
        )
        do {
            try diagnostics.activate()
            qobuzLog.info("lifecycle", "Native view model initialized")
        } catch {
            FileHandle.standardError.write(Data("Could not activate diagnostics: \(error.localizedDescription)\n".utf8))
        }
        lifecycle.configureProcessTermination(diagnostics: diagnostics)
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

    func queueTrackSelection(for request: QobuzRequest) -> Set<QobuzID>? {
        queueOrchestrator.selectedTrackIDs(for: request)
    }

    func toggleSelectedQueueTrack(_ trackID: QobuzID) {
        queueOrchestrator.toggleSelectedTrack(trackID, mutationsAllowed: !isDownloading)
    }

    func selectAllSelectedQueueTracks() {
        queueOrchestrator.selectAllSelectedTracks(mutationsAllowed: !isDownloading)
    }

    func clearSelectedQueueTracks() {
        queueOrchestrator.clearSelectedTracks(mutationsAllowed: !isDownloading)
    }

    var canDownloadSelected: Bool { lifecycle.isReady && downloadOrchestrator.canDownloadSelected }

    var canDownloadAll: Bool { lifecycle.isReady && downloadOrchestrator.canDownloadAll }

    var canDownloadNext: Bool { canDownloadAll }

    var isDownloading: Bool { downloads.isDownloading }
    var canCancel: Bool { lifecycle.isReady && downloads.isDownloading }
    var canClearActivity: Bool { downloads.canClearActivity }
    var settings: NativeSettings { account.settings }
    var credentials: CredentialDraft { account.credentials }
    var accountRegion: String? { account.accountRegion }
    private var client: (any NativeQobuzServicing)? { account.client }
    var regionDisplay: String { account.regionDisplay }
    var isStartupInProgress: Bool { lifecycle.isStarting }
    var canRetryStartup: Bool { lifecycle.canRetry }
    var canInteractWithContent: Bool { lifecycle.isReady }
    var canEditConfiguration: Bool { lifecycle.canEditConfiguration }

    func status(for item: NativeQueueItem) -> NativeDownloadStatus {
        downloads.status(for: item)
    }

    func status(for activity: NativeDownloadActivity) -> NativeDownloadStatus {
        downloads.status(for: activity)
    }

    func detailError(for activity: NativeDownloadActivity) -> String? {
        downloads.detailError(for: activity)
    }

    @discardableResult
    func exportDiagnostics(to parent: URL) async throws -> URL {
        try await diagnostics.export(snapshot: diagnosticSnapshotBuilder.makeSnapshot(), to: parent)
    }

    func start() async {
        await lifecycle.start(
            onValidateAccount: { [weak self] in await self?.testConnection(showSuccess: false) },
            onOpenURL: { [weak self] url in self?.handleOpenURLReady(url) },
            onNotice: { [weak self] message in self?.notice = message },
            onRequireSettings: { [weak self] in self?.showSettings = true }
        )
    }

    var settingsDraft: SettingsDraft {
        account.draft
    }

    func saveConfiguration(_ draft: SettingsDraft) throws {
        applyConfigurationChange(try configurationMutations.save(draft))
    }

    func saveConfiguration(credentials: CredentialDraft, settings: NativeSettings) throws {
        applyConfigurationChange(try configurationMutations.save(credentials: credentials, settings: settings))
    }

    func testConnection(showSuccess: Bool = true) async {
        do {
            _ = try await account.validateConnection()
            lifecycle.synchronizeAccountRegion()
            if showSuccess {
                notice = account.accountRegion == nil
                    ? "Connected to Qobuz."
                    : "Connected to the \(regionDisplay) Qobuz account."
            }
        } catch let error where error.isQobuzCancellation {
            return
        } catch {
            lifecycle.synchronizeAccountRegion()
            notice = error.localizedDescription
        }
    }

    func submitInput() {
        let outcome = requestIntake.submit(input)
        switch outcome.action {
        case .open(let request): openRequest(request)
        case .search(let query): search(query)
        case nil: break
        }
        if outcome.clearsInput { input = "" }
        if outcome.updatesNotice { notice = outcome.notice }
        if outcome.requiresConfiguration { showSettings = true }
    }

    func addText(_ text: String) {
        input = text
        submitInput()
    }

    func importLinks(from url: URL) {
        do {
            addText(try requestIntake.importedText(from: url))
        } catch {
            notice = "Could not read the text file: \(error.localizedDescription)"
        }
    }

    func handleOpenURL(_ url: URL) {
        guard lifecycle.shouldHandleOpenURL(url) else { return }
        handleOpenURLReady(url)
    }

    private func handleOpenURLReady(_ url: URL) {
        switch requestIntake.submittedText(from: url) {
        case .success(let text): addText(text)
        case .failure(let message): notice = message
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

    func addRequest(
        _ request: QobuzRequest,
        title: String? = nil,
        subtitle: String? = nil,
        artworkURL: URL? = nil
    ) {
        applyNotice(
            queueOrchestrator.addRequest(
                request,
                title: title,
                subtitle: subtitle,
                artworkURL: artworkURL,
                client: client,
                unavailabilityMessage: unavailableTrackMessage
            )
        )
    }

    func addAlbums(_ albums: [QobuzAlbum]) {
        applyNotice(
            queueOrchestrator.addAlbums(
                albums,
                client: client,
                unavailabilityMessage: unavailableTrackMessage
            )
        )
    }

    func selectQueueItem(_ id: UUID?) {
        queueOrchestrator.select(id, client: client, unavailabilityMessage: unavailableTrackMessage)
    }

    func removeQueueItem(_ id: UUID) {
        queueOrchestrator.remove(id, client: client, unavailabilityMessage: unavailableTrackMessage)
    }

    func clearQueue() {
        queueOrchestrator.clear(client: client, unavailabilityMessage: unavailableTrackMessage)
    }

    func setQueueQuality(_ quality: QobuzQuality?, for id: UUID) {
        queueOrchestrator.setQuality(quality, for: id, mutationsAllowed: !isDownloading)
    }

    func toggleQueueTrack(_ trackID: QobuzID, in id: UUID) {
        queueOrchestrator.toggleTrack(trackID, in: id, mutationsAllowed: !isDownloading)
    }

    func selectAllQueueTracks(in id: UUID) {
        queueOrchestrator.selectAllTracks(in: id, mutationsAllowed: !isDownloading)
    }

    func clearQueueTrackSelection(in id: UUID) {
        queueOrchestrator.clearTrackSelection(in: id, mutationsAllowed: !isDownloading)
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
        browseNavigation.search(query)
    }

    func closeBrowse() {
        browseNavigation.close()
    }

    func openAlbum(_ id: QobuzID) {
        browseNavigation.open(BrowseDestination.album(id))
    }

    func openArtist(_ id: QobuzID) {
        browseNavigation.open(BrowseDestination.artist(id))
    }

    func openTrack(_ id: QobuzID) {
        browseNavigation.open(BrowseDestination.track(id))
    }

    func openPlaylist(_ id: QobuzID) {
        browseNavigation.open(BrowseDestination.playlist(id))
    }

    func openLabel(_ id: QobuzID) {
        browseNavigation.open(BrowseDestination.label(id))
    }

    func openRequest(_ request: QobuzRequest) {
        browseNavigation.open(request)
    }

    func browseBack() {
        browseNavigation.back()
    }

    func retryBrowsePage() {
        browseNavigation.retryPage()
    }

    func retryBrowseSearch() {
        browseNavigation.retrySearch()
    }

    func openLibrary() {
        browse.close()
        library.open(root: account.downloadRoot) { [weak self] message in self?.notice = message }
    }

    func closeLibrary() {
        library.close()
    }

    func refreshArchive(fullVerification: Bool = false) {
        library.refresh(
            root: account.downloadRoot,
            fullVerification: fullVerification,
            onFailure: { [weak self] message in self?.notice = message }
        )
    }

    func inspectLibraryForAdoption(at root: URL) async throws -> QobuzLibraryAdoptionPlan {
        try await libraryAdoption.inspect(
            at: root,
            mutationsBlocked: configurationMutations.isDownloadRootMutationBlocked
        )
    }

    func adoptLibrary(at root: URL, draft: SettingsDraft) async throws {
        try lifecycle.requireConfigurationMutationPermission()
        let adoption = try await libraryAdoption.adopt(
            at: root,
            draft: draft,
            downloadIsActive: isDownloading,
            mutationsBlocked: configurationMutations.isDownloadRootMutationBlocked
        )
        applyConfigurationChange(adoption.configurationChange)
        libraryAdoption.publish(adoption)
        browse.close()
        notice = adoption.notice
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

    func downloadSelected() {
        downloadOrchestrator.downloadSelected()
    }

    func downloadAll() {
        downloadOrchestrator.downloadAll()
    }

    func downloadNext() {
        downloadOrchestrator.downloadNext()
    }

    func resume(_ activity: NativeDownloadActivity) {
        downloadOrchestrator.resume(activity)
    }

    func retry(_ activity: NativeDownloadActivity) {
        downloadOrchestrator.retry(activity)
    }

    func canRestart(_ activity: NativeDownloadActivity) -> Bool {
        !libraryManagement.isWorking && downloads.canRestart(activity)
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
        downloadOrchestrator.repairArchiveTracks(tracks)
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
        lifecycle.prepareForTermination()
    }

    func reveal(_ activity: NativeDownloadActivity) {
        downloads.reveal(activity)
    }

    func revealDownloadRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.downloadPath, isDirectory: true)])
    }

    private func applyConfigurationChange(_ change: NativeConfigurationChange) {
        showSettings = false
        switch lifecycle.applyConfigurationChange(change) {
        case .retryStartup: Task { await start() }
        case .saved: notice = "Settings saved."
        case .validateAccount: Task { await testConnection(showSuccess: true) }
        }
    }

    private var unavailableTrackMessage: (QobuzTrack) -> String? {
        { [weak self] track in self?.browse.unavailabilityMessage(for: track) }
    }

    private func applyNotice(_ mutation: NativeNoticeMutation) {
        guard case .set(let message) = mutation else { return }
        notice = message
    }

}
