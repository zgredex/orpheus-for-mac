import AppKit
import Combine
import Foundation
import NativeQobuzCore

protocol NativeQobuzServicing: QobuzCatalogService, QobuzBrowsingService {}
extension QobuzAPIClient: NativeQobuzServicing {}

@MainActor
final class NativeViewModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var queue: [NativeQueueItem] = [] {
        didSet { scheduleSessionPersistence() }
    }
    @Published var selectedQueueID: UUID? {
        didSet { scheduleSessionPersistence() }
    }
    @Published private(set) var preview: NativePreviewState = .empty
    @Published private(set) var activities: [NativeDownloadActivity] = [] {
        didSet { scheduleSessionPersistence() }
    }
    @Published private(set) var linkInbox: [NativeLinkInboxItem] = [] {
        didSet { scheduleSessionPersistence() }
    }
    @Published private(set) var settings: NativeSettings
    @Published private(set) var credentials = CredentialDraft()
    @Published private(set) var accountRegion: String?
    @Published var notice: String?
    @Published var showSettings = false
    @Published var showDiagnostics = false

    @Published private(set) var browseQuery = ""
    @Published var browseCategory: NativeBrowseCategory = .albums
    @Published private(set) var browseResults = NativeBrowseResults()
    @Published private(set) var loadingBrowseCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var loadingMoreBrowseCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var browseErrors: [NativeBrowseCategory: String] = [:]
    @Published private(set) var browseLoadMoreErrors: [NativeBrowseCategory: String] = [:]
    @Published private(set) var isBrowseOpen = false
    @Published private(set) var browsePath: [BrowsePage] = []
    @Published private(set) var isLibraryOpen = false
    @Published private(set) var archiveSnapshot: QobuzArchiveSnapshot?
    @Published private(set) var isArchiveScanning = false
    @Published private(set) var connectivityState: NativeConnectivityState = .unknown

    private let settingsStore: any NativeSettingsStoring
    private let credentialStore: any NativeCredentialStoring
    private let archiveStore: any NativeArchiveIndexStoring
    private let sessionStore: any NativeSessionStoring
    private let diagnostics: NativeDiagnosticsController
    private let archiveScanner: any QobuzArchiveScanning
    private let libraryAdopter: any QobuzLibraryAdopting
    private let connectivityMonitor: any NativeConnectivityMonitoring
    private let powerActivityManager: any NativePowerActivityManaging
    private let clientFactory: (QobuzCredentials) -> any NativeQobuzServicing
    private var client: (any NativeQobuzServicing)?
    private var previewTask: Task<Void, Never>?
    private var browseTasks: [Task<Void, Never>] = []
    private var browseRequestID: UUID?
    private var browsePageTask: Task<Void, Never>?
    private var linkInboxTask: Task<Void, Never>?
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
        self.settingsStore = settingsStore ?? NativeSettingsStore(paths: paths)
        self.credentialStore = credentialStore ?? FileCredentialStore(paths: paths)
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
        self.clientFactory = clientFactory
        settings = NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes)
        do {
            try diagnostics.activate()
            qobuzLog.info("lifecycle", "Native view model initialized")
        } catch {
            FileHandle.standardError.write(Data("Could not activate diagnostics: \(error.localizedDescription)\n".utf8))
        }
    }

    var selectedQueueItem: NativeQueueItem? {
        queue.first { $0.id == selectedQueueID }
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
    var isBrowseLoading: Bool {
        !loadingBrowseCategories.isEmpty || !loadingMoreBrowseCategories.isEmpty
    }

    var browseStatusText: String {
        if !loadingBrowseCategories.isEmpty {
            return "Searching all categories"
        }
        let loaded = browseResults.totalCount
        if !loadingMoreBrowseCategories.isEmpty {
            return "\(loaded) loaded · Loading more"
        }
        if browseResults.hasMoreResults {
            return "\(loaded) loaded"
        }
        return loaded == 1 ? "1 result" : "\(loaded) results"
    }

    var browseAlbums: [QobuzAlbumSummary] { browseResults.albums }
    var browseArtists: [QobuzArtist] { browseResults.artists }
    var browsePlaylists: [QobuzPlaylist] { browseResults.playlists }
    var browseTracks: [QobuzTrack] { browseResults.tracks }

    var regionDisplay: String {
        guard let accountRegion else { return "Qobuz" }
        guard let flag = CountryFlag.emoji(for: accountRegion) else { return accountRegion }
        return "\(flag) \(accountRegion.uppercased())"
    }

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
            settings = try settingsStore.load()
            credentials = try credentialStore.load() ?? CredentialDraft()
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
            configureClient()
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
        SettingsDraft(credentials: credentials, quality: settings.quality, downloadPath: settings.downloadPath)
    }

    func saveConfiguration(_ draft: SettingsDraft) throws {
        try saveConfiguration(
            credentials: draft.credentials,
            settings: NativeSettings(downloadPath: draft.downloadPath, quality: draft.quality)
        )
    }

    func saveConfiguration(credentials: CredentialDraft, settings: NativeSettings) throws {
        guard !isDownloading else {
            qobuzLog.warning("settings", "Settings change blocked during an active download")
            throw NativeQobuzError.unavailable("Settings cannot change during a download.")
        }
        let rootChanged = self.settings.downloadPath != settings.downloadPath
        qobuzLog.notice(
            "settings",
            "Saving app configuration",
            metadata: [
                "downloadPath": settings.downloadPath,
                "quality": settings.quality.rawValue,
                "rootChanged": String(rootChanged),
                "credentialsConfigured": String(credentials.isComplete)
            ]
        )
        do {
            try settingsStore.save(settings)
            try credentialStore.save(credentials)
            self.settings = settings
            self.credentials = credentials
            if rootChanged {
                archiveTask?.cancel()
                archiveRefreshID = nil
                archiveSnapshot = nil
                isArchiveScanning = false
            }
            configureClient()
            showSettings = false
            qobuzLog.notice("settings", "App configuration saved")
            Task { await testConnection(showSuccess: true) }
        } catch {
            qobuzLog.error("settings", "App configuration could not be saved", error: error)
            throw error
        }
    }

    func testConnection(showSuccess: Bool = true) async {
        guard let client else {
            qobuzLog.warning(
                "account.connection",
                "Qobuz connection test blocked because credentials are incomplete",
                metadata: ["credentialsConfigured": "false"]
            )
            notice = "Enter complete Qobuz credentials first."
            return
        }
        let testID = UUID().uuidString
        let startedAt = Date()
        qobuzLog.info(
            "account.connection",
            "Qobuz connection test started",
            metadata: ["connectionTestID": testID]
        )
        do {
            accountRegion = try await QobuzLogScope.withValue(["connectionTestID": testID]) {
                try await client.validateAccount()
            }
            qobuzLog.notice(
                "account.connection",
                "Qobuz connection test succeeded",
                metadata: [
                    "connectionTestID": testID,
                    "accountRegion": accountRegion ?? "unknown",
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ]
            )
            if showSuccess { notice = "Connected to the \(regionDisplay) Qobuz account." }
        } catch {
            accountRegion = nil
            qobuzLog.error(
                "account.connection",
                "Qobuz connection test failed",
                metadata: [
                    "connectionTestID": testID,
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ],
                error: error
            )
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
        guard let item = linkInbox.first(where: { $0.id == id }) else { return }
        openRequest(item.request)
    }

    func removeInboxItem(_ id: UUID) {
        linkInbox.removeAll { $0.id == id }
    }

    func clearReviewedLinks() {
        linkInbox.removeAll { $0.status.isReviewed }
    }

    func clearLinkInbox() {
        linkInboxTask?.cancel()
        linkInbox.removeAll()
    }

    func retryInboxItem(_ id: UUID) {
        guard let item = linkInbox.first(where: { $0.id == id }) else { return }
        reviewInboxItems([(item.id, item.request)])
    }

    private func reviewLinks(_ links: [ParsedQobuzLink]) {
        let known = Set(linkInbox.map { $0.canonicalURL.absoluteString })
        var seen = known
        let newItems = links.compactMap { link -> NativeLinkInboxItem? in
            guard seen.insert(link.canonicalURL.absoluteString).inserted else { return nil }
            return NativeLinkInboxItem(link: link)
        }
        guard !newItems.isEmpty else {
            notice = "Those links are already in the review inbox."
            return
        }
        linkInbox.append(contentsOf: newItems)
        reviewInboxItems(newItems.map { ($0.id, $0.request) })
    }

    private func reviewInboxItems(_ items: [(UUID, QobuzRequest)]) {
        guard let client else {
            for (id, _) in items {
                updateInbox(id) { $0.status = .failed("Configure Qobuz credentials to verify this link.") }
            }
            showSettings = true
            return
        }
        linkInboxTask?.cancel()
        var workByID = Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.1) })
        for item in linkInbox {
            switch item.status {
            case .pending, .checking: workByID[item.id] = item.request
            default: break
            }
        }
        let work = linkInbox.compactMap { item in workByID[item.id].map { (item.id, $0) } }
        for (id, _) in work { updateInbox(id) { $0.status = .checking } }
        linkInboxTask = Task { [weak self] in
            await withTaskGroup(of: NativeInboxReviewResult.self) { group in
                var next = 0
                let limit = min(3, work.count)
                for _ in 0..<limit {
                    let value = work[next]
                    next += 1
                    group.addTask { await Self.fetchInboxReview(id: value.0, request: value.1, client: client) }
                }
                while let result = await group.next() {
                    guard let self, !Task.isCancelled else { return }
                    self.applyInboxReview(result)
                    if next < work.count {
                        let value = work[next]
                        next += 1
                        group.addTask { await Self.fetchInboxReview(id: value.0, request: value.1, client: client) }
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            linkInboxTask = nil
        }
    }

    func addRequest(
        _ request: QobuzRequest,
        title: String? = nil,
        subtitle: String? = nil,
        artworkURL: URL? = nil
    ) {
        guard !queue.contains(where: { $0.canonicalURL == request.canonicalURL }) else {
            qobuzLog.info(
                "queue",
                "Duplicate Qobuz request was not added",
                metadata: ["requestKind": request.kindName, "qobuzID": request.id.rawValue]
            )
            notice = "That Qobuz item is already queued."
            return
        }
        var item = NativeQueueItem(request: request, title: title)
        if let subtitle { item.subtitle = subtitle }
        item.artworkURL = artworkURL
        queue.append(item)
        updateDownloadState { $0.registerQueue(item.id) }
        qobuzLog.notice(
            "queue",
            "Qobuz request added to queue",
            metadata: [
                "queueID": item.id.uuidString,
                "requestKind": request.kindName,
                "qobuzID": request.id.rawValue,
                "queueCount": String(queue.count)
            ]
        )
        selectQueueItem(item.id)
    }

    func addAlbums(_ albums: [QobuzAlbum]) {
        var knownURLs = Set(queue.map(\.canonicalURL))
        var added: [NativeQueueItem] = []
        var skipped = 0

        for album in albums where album.accountAvailabilityIssue == nil {
            let request = QobuzRequest.album(album.id)
            guard knownURLs.insert(request.canonicalURL).inserted else {
                skipped += 1
                continue
            }
            var item = NativeQueueItem(request: request, title: album.displayTitle)
            item.subtitle = album.albumArtistDisplayName
            item.artworkURL = album.image?.bestURL
            added.append(item)
        }

        guard !added.isEmpty else {
            if skipped > 0 { notice = "Those editions are already queued." }
            return
        }
        queue.append(contentsOf: added)
        updateDownloadState { $0.registerQueues(added.map(\.id)) }
        qobuzLog.notice(
            "queue",
            "Album editions added to queue",
            metadata: [
                "addedCount": String(added.count),
                "duplicateCount": String(skipped),
                "queueCount": String(queue.count)
            ]
        )
        selectQueueItem(added[0].id)
        if skipped > 0 {
            let noun = skipped == 1 ? "edition" : "editions"
            notice = "Skipped \(skipped) already queued \(noun)."
        } else {
            notice = nil
        }
    }

    func selectQueueItem(_ id: UUID?) {
        selectedQueueID = id
        guard let id, let item = queue.first(where: { $0.id == id }) else {
            qobuzLog.debug("queue.selection", "Queue selection cleared")
            preview = .empty
            return
        }
        qobuzLog.debug(
            "queue.selection",
            "Queue item selected",
            metadata: ["queueID": id.uuidString, "requestKind": item.request.kindName, "qobuzID": item.request.id.rawValue]
        )
        loadPreview(item)
    }

    func removeQueueItem(_ id: UUID) {
        guard !downloadState.status(forQueueID: id).isActive else {
            qobuzLog.warning("queue", "Active download could not be removed", metadata: ["queueID": id.uuidString])
            return
        }
        queue.removeAll { $0.id == id }
        updateDownloadState { $0.removeQueue(id) }
        qobuzLog.notice(
            "queue",
            "Queue item removed",
            metadata: ["queueID": id.uuidString, "queueCount": String(queue.count)]
        )
        if selectedQueueID == id { selectQueueItem(queue.first?.id) }
    }

    func clearQueue() {
        let before = queue.count
        let activeIDs = Set(queue.filter { status(for: $0).isActive }.map(\.id))
        let removedIDs = Set(queue.map(\.id)).subtracting(activeIDs)
        queue.removeAll { !activeIDs.contains($0.id) }
        updateDownloadState { state in
            for id in removedIDs { state.removeQueue(id) }
        }
        qobuzLog.notice(
            "queue",
            "Inactive queue items cleared",
            metadata: ["removedCount": String(before - queue.count), "retainedActiveCount": String(queue.count)]
        )
        selectQueueItem(queue.first?.id)
    }

    func setQueueQuality(_ quality: QobuzQuality?, for id: UUID) {
        guard !isDownloading,
              queue.first(where: { $0.id == id })?.repairTarget == nil else { return }
        updateQueue(id) { item in
            item.downloadQuality = quality
        }
        resetQueueStatusAfterPlanChange(id)
        qobuzLog.info(
            "queue.plan",
            "Queue quality override changed",
            metadata: ["queueID": id.uuidString, "quality": quality?.rawValue ?? "default"]
        )
    }

    func toggleQueueTrack(_ trackID: QobuzID, in id: UUID) {
        guard !isDownloading,
              queue.first(where: { $0.id == id })?.trackPlan != nil else { return }
        updateQueue(id) { item in
            var selected = item.effectiveSelectedTrackIDs
            if selected.contains(trackID) { selected.remove(trackID) }
            else if item.availableTrackIDs.contains(trackID) { selected.insert(trackID) }
            item.selectedTrackIDs = selected
        }
        resetQueueStatusAfterPlanChange(id)
        if let item = queue.first(where: { $0.id == id }) {
            qobuzLog.info(
                "queue.plan",
                "Queue track selection changed",
                metadata: [
                    "queueID": id.uuidString,
                    "trackID": trackID.rawValue,
                    "selectedTrackCount": String(item.effectiveSelectedTrackIDs.count)
                ]
            )
        }
    }

    func selectAllQueueTracks(in id: UUID) {
        guard !isDownloading,
              queue.first(where: { $0.id == id })?.trackPlan != nil else { return }
        updateQueue(id) { item in
            item.selectedTrackIDs = nil
        }
        resetQueueStatusAfterPlanChange(id)
        qobuzLog.info("queue.plan", "All available queue tracks selected", metadata: ["queueID": id.uuidString])
    }

    func clearQueueTrackSelection(in id: UUID) {
        guard !isDownloading,
              queue.first(where: { $0.id == id })?.trackPlan != nil else { return }
        updateQueue(id) { item in
            item.selectedTrackIDs = []
        }
        resetQueueStatusAfterPlanChange(id)
        qobuzLog.info("queue.plan", "Queue track selection cleared", metadata: ["queueID": id.uuidString])
    }

    func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        guard !isDownloading, !offsets.isEmpty else { return }
        let moving = offsets.sorted().map { queue[$0] }
        for index in offsets.sorted(by: >) { queue.remove(at: index) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = min(max(destination - removedBeforeDestination, 0), queue.count)
        queue.insert(contentsOf: moving, at: insertion)
        qobuzLog.debug(
            "queue.order",
            "Queue items reordered",
            metadata: ["movedCount": String(moving.count), "destinationIndex": String(insertion)]
        )
    }

    func moveQueueItem(_ sourceID: UUID, before targetID: UUID) {
        guard !isDownloading,
              sourceID != targetID,
              let source = queue.firstIndex(where: { $0.id == sourceID }),
              queue.contains(where: { $0.id == targetID }) else { return }
        let item = queue.remove(at: source)
        guard let target = queue.firstIndex(where: { $0.id == targetID }) else { return }
        queue.insert(item, at: target)
    }

    func moveQueueItemUp(_ id: UUID) {
        guard !isDownloading,
              let index = queue.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        queue.swapAt(index, index - 1)
    }

    func moveQueueItemDown(_ id: UUID) {
        guard !isDownloading,
              let index = queue.firstIndex(where: { $0.id == id }),
              index + 1 < queue.count else { return }
        queue.swapAt(index, index + 1)
    }

    func queuePreflight(for item: NativeQueueItem) -> NativeQueuePreflight {
        let selectedIDs = item.effectiveSelectedTrackIDs
        let selectedCount: Int?
        let unavailable: Int
        if let trackPlan = item.trackPlan {
            selectedCount = trackPlan.count { $0.isAvailable && selectedIDs.contains($0.qobuzID) }
            unavailable = trackPlan.count { !$0.isAvailable }
        } else {
            selectedCount = item.selectedTrackIDs?.count ?? item.expectedTrackIDs?.count
            unavailable = 0
        }

        var verified = 0
        var problems = 0
        if let snapshot = archiveSnapshot, !selectedIDs.isEmpty {
            let albumID: QobuzID? = if case .album(let id) = item.request { id } else { nil }
            let coverage = snapshot.coverage(trackIDs: Array(selectedIDs), albumID: albumID)
            verified = coverage.verifiedCount
            problems = coverage.problemCount
        }
        return NativeQueuePreflight(
            total: item.trackPlan?.count,
            available: item.trackPlan?.filter(\.isAvailable).count,
            selected: selectedCount,
            unavailable: unavailable,
            verified: verified,
            problems: problems
        )
    }

    func search(_ query: String) {
        guard let client else {
            qobuzLog.warning("browse.search", "Search blocked because credentials are not configured")
            notice = "Configure Qobuz credentials before searching."
            showSettings = true
            return
        }
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
        let requestID = UUID()
        browseRequestID = requestID
        browseQuery = query
        browseResults = NativeBrowseResults()
        browseErrors = [:]
        browseLoadMoreErrors = [:]
        browsePageTask?.cancel()
        browsePath = []
        isLibraryOpen = false
        loadingBrowseCategories = Set(NativeBrowseCategory.allCases)
        loadingMoreBrowseCategories = []
        browseCategory = .albums
        isBrowseOpen = true
        qobuzLog.notice(
            "browse.search",
            "Catalog search started",
            metadata: ["searchID": requestID.uuidString, "query": query, "categoryCount": String(NativeBrowseCategory.allCases.count)]
        )

        for category in NativeBrowseCategory.allCases {
            browseTasks.append(Task { [weak self] in
                do {
                    let results = try await QobuzLogScope.withValue([
                        "searchID": requestID.uuidString,
                        "searchCategory": category.rawValue,
                        "searchQuery": query
                    ]) {
                        try await client.search(
                            query,
                            category: category.coreValue,
                            limit: 30,
                            offset: 0
                        )
                    }
                    guard let self, self.browseRequestID == requestID, !Task.isCancelled else { return }
                    let loadedCount = switch category {
                    case .albums: results.albums.count
                    case .artists: results.artists.count
                    case .playlists: results.playlists.count
                    case .tracks: results.tracks.count
                    }
                    qobuzLog.info(
                        "browse.search",
                        "Search category loaded",
                        metadata: [
                            "searchID": requestID.uuidString,
                            "category": category.rawValue,
                            "loadedCount": String(loadedCount),
                            "totalCount": results.total.map(String.init) ?? "unknown"
                        ]
                    )
                    self.apply(results, category: category)
                } catch {
                    guard let self, self.browseRequestID == requestID, !Task.isCancelled else { return }
                    qobuzLog.error(
                        "browse.search",
                        "Search category failed",
                        metadata: ["searchID": requestID.uuidString, "category": category.rawValue, "query": query],
                        error: error
                    )
                    self.loadingBrowseCategories.remove(category)
                    self.browseErrors[category] = error.localizedDescription
                }
            })
        }
    }

    func closeBrowse() {
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
        loadingBrowseCategories = []
        loadingMoreBrowseCategories = []
        browsePageTask?.cancel()
        browsePath = []
        isBrowseOpen = false
    }

    func openAlbum(_ id: QobuzID) {
        openBrowsePage(.album(id))
    }

    func openArtist(_ id: QobuzID) {
        openBrowsePage(.artist(id))
    }

    func openTrack(_ id: QobuzID) {
        openBrowsePage(.track(id))
    }

    func openPlaylist(_ id: QobuzID) {
        openBrowsePage(.playlist(id))
    }

    func openLabel(_ id: QobuzID) {
        openBrowsePage(.label(id))
    }

    func openRequest(_ request: QobuzRequest) {
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
        browsePageTask?.cancel()
        browseRequestID = nil
        browseQuery = ""
        browseResults = NativeBrowseResults()
        browseErrors = [:]
        browseLoadMoreErrors = [:]
        loadingBrowseCategories = []
        loadingMoreBrowseCategories = []
        browsePath = []

        switch request {
        case .album(let id): openAlbum(id)
        case .artist(let id): openArtist(id)
        case .track(let id): openTrack(id)
        case .playlist(let id): openPlaylist(id)
        case .label(let id): openLabel(id)
        }
    }

    func browseBack() {
        browsePageTask?.cancel()
        _ = browsePath.popLast()
        if browsePath.isEmpty, browseQuery.isEmpty {
            closeBrowse()
        }
    }

    func retryBrowsePage() {
        guard let page = browsePath.popLast() else { return }
        openBrowsePage(page.destination)
    }

    private func openBrowsePage(_ destination: BrowseDestination) {
        guard let client else {
            qobuzLog.warning("browse.page", "Browse page blocked because credentials are not configured")
            notice = "Configure Qobuz credentials before browsing."
            showSettings = true
            return
        }
        browsePageTask?.cancel()
        isLibraryOpen = false
        let page = BrowsePage(id: UUID(), destination: destination, content: .loading)
        let destinationMetadata: [String: String] = switch destination {
        case .album(let id): ["browseKind": "album", "qobuzID": id.rawValue]
        case .artist(let id): ["browseKind": "artist", "qobuzID": id.rawValue]
        case .track(let id): ["browseKind": "track", "qobuzID": id.rawValue]
        case .playlist(let id): ["browseKind": "playlist", "qobuzID": id.rawValue]
        case .label(let id): ["browseKind": "label", "qobuzID": id.rawValue]
        }
        let pageMetadata = destinationMetadata.merging(["browsePageID": page.id.uuidString]) { _, new in new }
        browsePath.append(page)
        isBrowseOpen = true
        qobuzLog.info("browse.page", "Browse page loading started", metadata: pageMetadata)
        browsePageTask = Task { [weak self] in
            do {
                let (content, availability): (BrowsePageContent, NativeBrowseAvailability) = try await QobuzLogScope.withValue(pageMetadata) {
                    switch destination {
                    case .album(let id):
                        let value = try await client.album(id: id)
                        return (.album(value), self?.availability(for: value) ?? .checking)
                    case .artist(let id):
                        let value = try await client.artist(id: id)
                        return (.artist(value), self?.availability(for: value) ?? .checking)
                    case .track(let id):
                        let value = try await client.track(id: id)
                        return (.track(value), self?.availability(for: value) ?? .checking)
                    case .playlist(let id):
                        let value = try await client.playlist(id: id)
                        return (.playlist(value), self?.availability(for: value) ?? .checking)
                    case .label(let id):
                        let value = try await client.label(id: id)
                        return (.label(value), self?.availability(for: value) ?? .checking)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                qobuzLog.info("browse.page", "Browse page loaded", metadata: pageMetadata)
                updateBrowsePage(page.id, content: content, availability: availability)
            } catch {
                guard let self, !Task.isCancelled else { return }
                qobuzLog.error("browse.page", "Browse page failed to load", metadata: pageMetadata, error: error)
                let message = browseErrorMessage(error)
                updateBrowsePage(
                    page.id,
                    content: .error(message),
                    availability: browseFailureAvailability(error, message: message)
                )
            }
        }
    }

    private func updateBrowsePage(
        _ id: UUID,
        content: BrowsePageContent,
        availability: NativeBrowseAvailability
    ) {
        guard let index = browsePath.firstIndex(where: { $0.id == id }) else { return }
        browsePath[index].content = content
        browsePath[index].availability = availability
    }

    func availability(for album: QobuzAlbum) -> NativeBrowseAvailability {
        if let issue = album.accountAvailabilityIssue {
            return .unavailable(availabilityMessage(for: issue, item: "This album"))
        }
        let available = album.availableTracks.count
        let unavailable = album.unavailableTrackCount
        guard available > 0 else {
            return .unavailable("None of this album's tracks are available for \(accountDescription).")
        }
        guard unavailable > 0 else { return .available }
        let trackWord = unavailable == 1 ? "track is" : "tracks are"
        return .partial(
            "\(available) of \(album.tracks.count) tracks are available for \(accountDescription). "
                + "The \(unavailable) unavailable \(trackWord) shown below and will be skipped."
        )
    }

    func availability(for track: QobuzTrack) -> NativeBrowseAvailability {
        guard let issue = track.accountAvailabilityIssue else { return .available }
        return .unavailable(availabilityMessage(for: issue, item: "This track"))
    }

    func availability(for playlist: QobuzPlaylist) -> NativeBrowseAvailability {
        let available = playlist.availableTracks.count
        let unavailable = playlist.unavailableTrackCount
        guard available > 0 else {
            return .unavailable("None of this playlist's tracks are available for \(accountDescription).")
        }
        guard unavailable > 0 else { return .available }
        return .partial(
            "\(available) of \(playlist.tracks.count) tracks are available for \(accountDescription). "
                + "Unavailable tracks are shown below and will be skipped."
        )
    }

    func availability(for artist: QobuzArtistCatalog) -> NativeBrowseAvailability {
        let allOfficial = artist.allOfficialAlbums
        let available = artist.officialAlbums
        guard !available.isEmpty else {
            return .unavailable("Qobuz returned no available official releases for this artist and \(accountDescription).")
        }
        let unavailable = allOfficial.count - available.count
        guard unavailable > 0 else { return .available }
        let releaseWord = unavailable == 1 ? "release is" : "releases are"
        return .partial(
            "\(available.count) of \(allOfficial.count) official releases are available for \(accountDescription). "
                + "The \(unavailable) unavailable \(releaseWord) excluded."
        )
    }

    func availability(for label: QobuzLabelCatalog) -> NativeBrowseAvailability {
        let available = label.availableAlbums.count
        guard available > 0 else {
            return .unavailable("Qobuz returned no albums from this label for \(accountDescription).")
        }
        let total = label.albums.count
        guard available < total else { return .available }
        return .partial(
            "\(available) of \(total) label albums are available for \(accountDescription). Unavailable albums are excluded."
        )
    }

    func unavailabilityMessage(for track: QobuzTrack) -> String? {
        guard let issue = track.accountAvailabilityIssue else { return nil }
        return availabilityMessage(for: issue, item: "Track")
    }

    private var accountDescription: String {
        accountRegion == nil ? "this Qobuz account" : "the \(regionDisplay) account"
    }

    private func availabilityMessage(for issue: QobuzAvailabilityIssue, item: String) -> String {
        switch issue {
        case .notDisplayable:
            "\(item) is not present in the catalog for \(accountDescription). It may belong to another region or have been removed."
        case .notStreamable:
            "\(item) is not streamable for \(accountDescription)."
        case .notPurchasable:
            "\(item) is not purchasable in the store for \(accountDescription)."
        }
    }

    private func browseErrorMessage(_ error: Error) -> String {
        guard let qobuzError = error as? NativeQobuzError else {
            return error.localizedDescription
        }
        switch qobuzError {
        case .unavailable:
            return "Qobuz did not return this item for \(accountDescription). It may belong to another region, be unavailable, or have been removed."
        case .emptyCollection:
            return "Qobuz returned no available tracks for this item and \(accountDescription)."
        default:
            return error.localizedDescription
        }
    }

    private func browseFailureAvailability(
        _ error: Error,
        message: String
    ) -> NativeBrowseAvailability {
        guard let qobuzError = error as? NativeQobuzError else { return .checking }
        switch qobuzError {
        case .unavailable, .emptyCollection:
            return .unavailable(message)
        default:
            return .checking
        }
    }

    func retryBrowseSearch() {
        guard !browseQuery.isEmpty else { return }
        let category = browseCategory
        search(browseQuery)
        browseCategory = category
    }

    func openLibrary() {
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
        browsePageTask?.cancel()
        browsePath = []
        isBrowseOpen = false
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
            isBrowseOpen = false
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
        browseResults.count(for: category)
    }

    func browseCountLabel(for category: NativeBrowseCategory) -> String {
        let loaded = browseResults.count(for: category)
        let hasMore = browseResults.nextOffset(for: category) != nil
        return "\(loaded)\(hasMore ? "+" : "")"
    }

    func canLoadMoreBrowseResults(for category: NativeBrowseCategory) -> Bool {
        browseResults.nextOffset(for: category) != nil
    }

    func isLoadingMoreBrowseResults(for category: NativeBrowseCategory) -> Bool {
        loadingMoreBrowseCategories.contains(category)
    }

    func loadMoreBrowseResults(for category: NativeBrowseCategory) {
        guard let client,
              let requestID = browseRequestID,
              let offset = browseResults.nextOffset(for: category),
              !loadingMoreBrowseCategories.contains(category),
              !browseQuery.isEmpty else { return }

        let query = browseQuery
        loadingMoreBrowseCategories.insert(category)
        browseLoadMoreErrors.removeValue(forKey: category)
        qobuzLog.info(
            "browse.pagination",
            "Loading next search result page",
            metadata: [
                "searchID": requestID.uuidString,
                "category": category.rawValue,
                "offset": String(offset),
                "query": query
            ]
        )
        let task = Task { [weak self] in
            do {
                let results = try await QobuzLogScope.withValue([
                    "searchID": requestID.uuidString,
                    "searchCategory": category.rawValue,
                    "searchOffset": String(offset)
                ]) {
                    try await client.search(
                        query,
                        category: category.coreValue,
                        limit: 30,
                        offset: offset
                    )
                }
                guard let self,
                      self.browseRequestID == requestID,
                      self.browseQuery == query,
                      !Task.isCancelled else { return }
                self.browseResults.append(results, for: category)
                self.loadingMoreBrowseCategories.remove(category)
                qobuzLog.info(
                    "browse.pagination",
                    "Next search result page loaded",
                    metadata: [
                        "searchID": requestID.uuidString,
                        "category": category.rawValue,
                        "offset": String(offset),
                        "nextOffset": results.nextOffset.map(String.init) ?? "none",
                        "loadedTotal": String(self.browseResults.count(for: category))
                    ]
                )
            } catch {
                guard let self,
                      self.browseRequestID == requestID,
                      self.browseQuery == query,
                      !Task.isCancelled else { return }
                qobuzLog.error(
                    "browse.pagination",
                    "Next search result page failed",
                    metadata: ["searchID": requestID.uuidString, "category": category.rawValue, "offset": String(offset)],
                    error: error
                )
                self.loadingMoreBrowseCategories.remove(category)
                self.browseLoadMoreErrors[category] = error.localizedDescription
            }
        }
        browseTasks.append(task)
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
            if let index = queue.firstIndex(where: {
                $0.repairTarget?.relativePath == target.relativePath
                    || ($0.repairTarget == nil && $0.canonicalURL == request.canonicalURL)
            }) {
                guard !downloadState.status(forQueueID: queue[index].id).isActive else { continue }
                queue[index].repairTarget = target
                queue[index].title = URL(fileURLWithPath: target.relativePath).lastPathComponent
                queue[index].subtitle = "Repair · \(target.audioFormat?.displayName ?? "Format \(target.formatID)")"
                transitionDownload(queueID: queue[index].id, to: .ready)
                ids.append(queue[index].id)
            } else {
                let item = NativeQueueItem(repairTarget: target)
                queue.append(item)
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
        linkInboxTask?.cancel()
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

    private func configureClient() {
        client = credentials.isComplete ? clientFactory(credentials.coreValue) : nil
        qobuzLog.info(
            "account.client",
            "Qobuz client configuration updated",
            metadata: ["credentialsConfigured": String(credentials.isComplete), "clientAvailable": String(client != nil)]
        )
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
        queue = snapshot.queue
        activities = snapshot.activities
        linkInbox = snapshot.linkInbox
        if let selected = snapshot.selectedQueueID,
           queue.contains(where: { $0.id == selected }) {
            selectedQueueID = selected
        } else {
            selectedQueueID = queue.first?.id
        }
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
        previewTask?.cancel()
        guard let client else {
            qobuzLog.warning(
                "queue.preview",
                "Queue preview blocked because credentials are not configured",
                metadata: ["queueID": item.id.uuidString]
            )
            preview = .error("Configure Qobuz credentials to load metadata.")
            return
        }
        preview = .loading
        let previewMetadata = [
            "queueID": item.id.uuidString,
            "requestKind": item.request.kindName,
            "qobuzID": item.request.id.rawValue
        ]
        qobuzLog.info("queue.preview", "Queue preview loading started", metadata: previewMetadata)
        previewTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await QobuzLogScope.withValue(previewMetadata) {
                  switch item.request {
                case .album(let id):
                    let value = try await client.album(id: id)
                    guard !Task.isCancelled else { return }
                    self.preview = .album(value)
                    self.updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.albumArtistDisplayName, artworkURL: value.image?.bestURL)
                    self.updateQueueTrackPlan(item.id, tracks: value.tracks)
                case .track(let id):
                    let value = try await client.track(id: id)
                    guard !Task.isCancelled else { return }
                    self.preview = .track(value)
                    self.updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.performer?.name ?? "Track", artworkURL: value.album?.image?.bestURL)
                    self.updateQueueTrackPlan(item.id, tracks: [value])
                case .playlist(let id):
                    let value = try await client.playlist(id: id)
                    guard !Task.isCancelled else { return }
                    self.preview = .playlist(value)
                    self.updateQueueMetadata(
                        item.id,
                        title: value.name,
                        subtitle: [value.owner?.name, "\(value.availableTracks.count) available tracks"]
                            .compactMap { $0 }.joined(separator: " · "),
                        artworkURL: value.artworkURL
                    )
                    self.updateQueueTrackPlan(item.id, tracks: value.tracks)
                case .artist(let id):
                    let value = try await client.artist(id: id)
                    guard !Task.isCancelled else { return }
                    self.preview = .artist(value)
                    let releaseCount = value.officialAlbums.count
                    self.updateQueueMetadata(
                        item.id,
                        title: value.name,
                        subtitle: "\(releaseCount) official \(releaseCount == 1 ? "release" : "releases")",
                        artworkURL: value.image?.bestURL
                    )
                case .label(let id):
                    let value = try await client.label(id: id)
                    guard !Task.isCancelled else { return }
                    self.preview = .label(value)
                    let albumCount = value.availableAlbums.count
                    self.updateQueueMetadata(
                        item.id,
                        title: value.name,
                        subtitle: "\(albumCount) available \(albumCount == 1 ? "album" : "albums")"
                    )
                }
                }
                qobuzLog.info("queue.preview", "Queue preview loaded", metadata: previewMetadata)
            } catch {
                guard let self, !Task.isCancelled else { return }
                qobuzLog.error("queue.preview", "Queue preview failed to load", metadata: previewMetadata, error: error)
                preview = .error(error.localizedDescription)
                transitionDownload(queueID: item.id, to: .failed(error.localizedDescription))
            }
        }
    }

    private func apply(_ results: QobuzSearchResults, category: NativeBrowseCategory) {
        browseResults.replace(results, for: category)
        loadingBrowseCategories.remove(category)
        if loadingBrowseCategories.isEmpty, browseCategory == .albums, browseAlbums.isEmpty {
            browseCategory = browseResults.firstNonemptyCategory ?? .albums
        }
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

    private static func fetchInboxReview(
        id: UUID,
        request: QobuzRequest,
        client: any NativeQobuzServicing
    ) async -> NativeInboxReviewResult {
        do {
            let payload: NativeInboxReviewPayload
            switch request {
            case .album(let value): payload = .album(try await client.album(id: value))
            case .artist(let value): payload = .artist(try await client.artist(id: value))
            case .track(let value): payload = .track(try await client.track(id: value))
            case .playlist(let value): payload = .playlist(try await client.playlist(id: value))
            case .label(let value): payload = .label(try await client.label(id: value))
            }
            return NativeInboxReviewResult(id: id, payload: payload, failure: nil)
        } catch let error as NativeQobuzError {
            return NativeInboxReviewResult(id: id, payload: nil, failure: .qobuz(error))
        } catch {
            return NativeInboxReviewResult(id: id, payload: nil, failure: .other(error.localizedDescription))
        }
    }

    private func applyInboxReview(_ result: NativeInboxReviewResult) {
        guard let payload = result.payload else {
            let status: NativeLinkReviewStatus
            switch result.failure {
            case .qobuz(let error):
                let message = browseErrorMessage(error)
                switch error {
                case .unavailable, .emptyCollection:
                    status = .unavailable(message)
                default:
                    status = .failed(message)
                }
            case .other(let message):
                status = .failed(message)
            case nil:
                status = .failed("Could not verify this Qobuz link.")
            }
            updateInbox(result.id) { $0.status = status }
            return
        }
        let values: (title: String, subtitle: String, artwork: URL?, availability: NativeBrowseAvailability)
        switch payload {
        case .album(let value):
            values = (
                value.displayTitle,
                value.mainArtists.map(\.name).joined(separator: ", "),
                value.image?.bestURL,
                availability(for: value)
            )
        case .artist(let value):
            values = (
                value.name,
                "\(value.officialAlbums.count) official releases",
                value.image?.bestURL,
                availability(for: value)
            )
        case .track(let value):
            values = (
                value.displayTitle,
                value.performer?.name ?? value.album?.title ?? "Track",
                value.album?.image?.bestURL,
                availability(for: value)
            )
        case .playlist(let value):
            values = (
                value.name,
                [value.owner?.name, "\(value.availableTracks.count) available tracks"]
                    .compactMap { $0 }.joined(separator: " · "),
                value.artworkURL,
                availability(for: value)
            )
        case .label(let value):
            values = (
                value.name,
                "\(value.availableAlbums.count) available albums",
                nil,
                availability(for: value)
            )
        }
        let status = reviewStatus(for: values.availability)
        updateInbox(result.id) { item in
            item.title = values.title
            item.subtitle = values.subtitle
            item.artworkURL = values.artwork
            item.status = status
        }
    }

    private func reviewStatus(for availability: NativeBrowseAvailability) -> NativeLinkReviewStatus {
        switch availability {
        case .checking: .checking
        case .available: .available
        case .partial(let message): .partial(message)
        case .unavailable(let message): .unavailable(message)
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
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        mutate(&queue[index])
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
        let plan = tracks.enumerated().map { offset, track in
            NativeQueueTrack(
                id: "\(track.id.rawValue)#\(offset)",
                qobuzID: track.id,
                title: track.displayTitle,
                subtitle: track.performer?.name ?? track.album?.title ?? "Track",
                duration: track.duration,
                position: offset + 1,
                unavailableReason: unavailabilityMessage(for: track)
            )
        }
        let available = Set(plan.filter(\.isAvailable).map(\.qobuzID))
        updateQueue(id) { item in
            item.trackPlan = plan
            item.expectedTrackIDs = plan.filter(\.isAvailable).map(\.qobuzID)
            if var selected = item.selectedTrackIDs {
                selected.formIntersection(available)
                item.selectedTrackIDs = selected
            }
        }
    }

    private func updateQueueMetadata(_ id: UUID, title: String, subtitle: String, artworkURL: URL? = nil) {
        updateQueue(id) { item in
            item.title = title
            item.subtitle = subtitle
            if let artworkURL { item.artworkURL = artworkURL }
        }
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

    private func updateInbox(_ id: UUID, mutate: (inout NativeLinkInboxItem) -> Void) {
        guard let index = linkInbox.firstIndex(where: { $0.id == id }) else { return }
        mutate(&linkInbox[index])
    }
}

private enum NativeInboxReviewPayload: Sendable {
    case album(QobuzAlbum)
    case artist(QobuzArtistCatalog)
    case track(QobuzTrack)
    case playlist(QobuzPlaylist)
    case label(QobuzLabelCatalog)
}

private struct NativeInboxReviewResult: Sendable {
    let id: UUID
    let payload: NativeInboxReviewPayload?
    let failure: NativeInboxReviewFailure?
}

private enum NativeInboxReviewFailure: Sendable {
    case qobuz(NativeQobuzError)
    case other(String)
}
