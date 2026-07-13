import AppKit
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
    @Published private(set) var settings: NativeSettings
    @Published private(set) var credentials = CredentialDraft()
    @Published private(set) var accountRegion = "??"
    @Published var notice: String?
    @Published var showSettings = false

    @Published private(set) var browseQuery = ""
    @Published var browseCategory: NativeBrowseCategory = .albums
    @Published private(set) var browseAlbums: [QobuzAlbumSummary] = []
    @Published private(set) var browseArtists: [QobuzArtist] = []
    @Published private(set) var browseTracks: [QobuzTrack] = []
    @Published private(set) var loadingBrowseCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var browseErrors: [NativeBrowseCategory: String] = [:]
    @Published private(set) var isBrowseOpen = false
    @Published private(set) var browsePath: [BrowsePage] = []
    @Published private(set) var isLibraryOpen = false
    @Published private(set) var archiveSnapshot: QobuzArchiveSnapshot?
    @Published private(set) var isArchiveScanning = false

    private let settingsStore: any NativeSettingsStoring
    private let credentialStore: any NativeCredentialStoring
    private let archiveStore: any NativeArchiveIndexStoring
    private let sessionStore: any NativeSessionStoring
    private let archiveScanner: any QobuzArchiveScanning
    private let clientFactory: (QobuzCredentials) -> any NativeQobuzServicing
    private var client: (any NativeQobuzServicing)?
    private var previewTask: Task<Void, Never>?
    private var browseTasks: [Task<Void, Never>] = []
    private var browseRequestID: UUID?
    private var browsePageTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var sessionPersistenceTask: Task<Void, Never>?
    private var lastProgressUpdate: [UUID: Date] = [:]
    private var started = false
    private var restoringSession = false
    private var isTerminating = false

    init(
        settingsStore: any NativeSettingsStoring = NativeSettingsStore(),
        credentialStore: any NativeCredentialStoring = FileCredentialStore(),
        archiveStore: any NativeArchiveIndexStoring = NativeArchiveIndexStore(),
        sessionStore: (any NativeSessionStoring)? = nil,
        archiveScanner: any QobuzArchiveScanning = QobuzArchiveScanner(),
        clientFactory: @escaping (QobuzCredentials) -> any NativeQobuzServicing = {
            QobuzAPIClient(credentials: $0)
        }
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.archiveStore = archiveStore
        let sessionPaths = (settingsStore as? NativeSettingsStore)?.paths ?? NativePaths()
        self.sessionStore = sessionStore ?? NativeSessionStore(paths: sessionPaths)
        self.archiveScanner = archiveScanner
        self.clientFactory = clientFactory
        let paths = NativePaths()
        settings = NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes)
    }

    var selectedQueueItem: NativeQueueItem? {
        queue.first { $0.id == selectedQueueID }
    }

    var canDownloadSelected: Bool {
        !isDownloading && selectedQueueItem?.status.canStart == true && credentials.isComplete
    }

    var canDownloadAll: Bool {
        !isDownloading && credentials.isComplete && queue.contains { $0.status.canStart }
    }

    var isDownloading: Bool { downloadTask != nil }
    var canCancel: Bool { downloadTask != nil }
    var canClearActivity: Bool { activities.contains { $0.status.isClearable } }
    var isBrowseLoading: Bool { !loadingBrowseCategories.isEmpty }

    var browseStatusText: String {
        if isBrowseLoading {
            return "Searching all categories"
        }
        let total = browseAlbums.count + browseArtists.count + browseTracks.count
        return total == 1 ? "1 result" : "\(total) results"
    }

    var regionDisplay: String {
        guard let flag = CountryFlag.emoji(for: accountRegion) else { return accountRegion }
        return "\(flag) \(accountRegion.uppercased())"
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            settings = try settingsStore.load()
            credentials = try credentialStore.load() ?? CredentialDraft()
            loadArchiveCache()
            do {
                try restoreSession()
            } catch {
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
        } catch {
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
        guard !isDownloading else { throw NativeQobuzError.unavailable("Settings cannot change during a download.") }
        let rootChanged = self.settings.downloadPath != settings.downloadPath
        try settingsStore.save(settings)
        try credentialStore.save(credentials)
        self.settings = settings
        self.credentials = credentials
        if rootChanged {
            archiveTask?.cancel()
            archiveSnapshot = nil
            isArchiveScanning = false
        }
        configureClient()
        showSettings = false
        Task { await testConnection(showSuccess: true) }
    }

    func testConnection(showSuccess: Bool = true) async {
        guard let client else {
            notice = "Enter complete Qobuz credentials first."
            return
        }
        do {
            accountRegion = try await client.validateAccount()
            if showSuccess { notice = "Connected to the \(regionDisplay) Qobuz account." }
        } catch {
            accountRegion = "??"
            notice = error.localizedDescription
        }
    }

    func submitInput() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let extraction = QobuzLinkParser.extract(
            from: value,
            knownCanonicalURLs: Set(queue.map { $0.canonicalURL.absoluteString })
        )
        if !extraction.links.isEmpty {
            add(extraction.links)
            input = ""
            isBrowseOpen = false
            var parts: [String] = []
            if extraction.duplicateCount > 0 { parts.append("\(extraction.duplicateCount) duplicate") }
            if !extraction.invalidQobuzURLs.isEmpty { parts.append("\(extraction.invalidQobuzURLs.count) invalid Qobuz URL") }
            notice = parts.isEmpty ? nil : parts.joined(separator: ", ")
        } else if !extraction.invalidQobuzURLs.isEmpty {
            notice = "The Qobuz URL is not a supported track, album, playlist, or artist link."
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
        do { addText(try String(contentsOf: url, encoding: .utf8)) }
        catch { notice = "Could not read the text file: \(error.localizedDescription)" }
    }

    func addRequest(_ request: QobuzRequest, title: String? = nil, artworkURL: URL? = nil) {
        guard !queue.contains(where: { $0.canonicalURL == request.canonicalURL }) else {
            notice = "That Qobuz item is already queued."
            return
        }
        var item = NativeQueueItem(request: request, title: title)
        item.artworkURL = artworkURL
        queue.append(item)
        selectQueueItem(item.id)
    }

    func addAlbums(_ albums: [QobuzAlbum]) {
        var knownURLs = Set(queue.map(\.canonicalURL))
        var added: [NativeQueueItem] = []
        var skipped = 0

        for album in albums where album.streamable && album.displayable {
            let request = QobuzRequest.album(album.id)
            guard knownURLs.insert(request.canonicalURL).inserted else {
                skipped += 1
                continue
            }
            var item = NativeQueueItem(request: request, title: album.displayTitle)
            item.subtitle = album.artist.name
            item.artworkURL = album.image?.bestURL
            added.append(item)
        }

        guard !added.isEmpty else {
            if skipped > 0 { notice = "Those editions are already queued." }
            return
        }
        queue.append(contentsOf: added)
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
            preview = .empty
            return
        }
        loadPreview(item)
    }

    func removeQueueItem(_ id: UUID) {
        guard queue.first(where: { $0.id == id })?.status != .downloading else { return }
        queue.removeAll { $0.id == id }
        if selectedQueueID == id { selectQueueItem(queue.first?.id) }
    }

    func clearQueue() {
        let activeIDs = Set(queue.filter { $0.status == .downloading }.map(\.id))
        queue.removeAll { !activeIDs.contains($0.id) }
        selectQueueItem(queue.first?.id)
    }

    func search(_ query: String) {
        guard let client else {
            notice = "Configure Qobuz credentials before searching."
            showSettings = true
            return
        }
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
        let requestID = UUID()
        browseRequestID = requestID
        browseQuery = query
        browseAlbums = []
        browseArtists = []
        browseTracks = []
        browseErrors = [:]
        browsePageTask?.cancel()
        browsePath = []
        isLibraryOpen = false
        loadingBrowseCategories = Set(NativeBrowseCategory.allCases)
        browseCategory = .albums
        isBrowseOpen = true

        for category in NativeBrowseCategory.allCases {
            browseTasks.append(Task { [weak self] in
                do {
                    let results = try await client.search(query, category: category.coreValue, limit: 30)
                    guard let self, self.browseRequestID == requestID, !Task.isCancelled else { return }
                    self.apply(results, category: category)
                } catch {
                    guard let self, self.browseRequestID == requestID, !Task.isCancelled else { return }
                    self.loadingBrowseCategories.remove(category)
                    self.browseErrors[category] = error.localizedDescription
                }
            })
        }
    }

    func closeBrowse() {
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
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
            notice = "Configure Qobuz credentials before browsing."
            showSettings = true
            return
        }
        browsePageTask?.cancel()
        isLibraryOpen = false
        let page = BrowsePage(id: UUID(), destination: destination, content: .loading)
        browsePath.append(page)
        isBrowseOpen = true
        browsePageTask = Task { [weak self] in
            do {
                let content: BrowsePageContent = switch destination {
                case .album(let id): .album(try await client.album(id: id))
                case .artist(let id): .artist(try await client.artist(id: id))
                }
                guard let self, !Task.isCancelled else { return }
                updateBrowsePage(page.id, content: content)
            } catch {
                guard let self, !Task.isCancelled else { return }
                updateBrowsePage(page.id, content: .error(error.localizedDescription))
            }
        }
    }

    private func updateBrowsePage(_ id: UUID, content: BrowsePageContent) {
        guard let index = browsePath.firstIndex(where: { $0.id == id }) else { return }
        browsePath[index].content = content
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

        if archiveSnapshot == nil,
           let cached = try? archiveStore.load(),
           cached.rootPath == URL(fileURLWithPath: settings.downloadPath).standardizedFileURL.path {
            archiveSnapshot = cached
        }
        refreshArchive()
    }

    func closeLibrary() {
        archiveTask?.cancel()
        isArchiveScanning = false
        isLibraryOpen = false
    }

    func refreshArchive() {
        archiveTask?.cancel()
        let root = URL(fileURLWithPath: settings.downloadPath, isDirectory: true).standardizedFileURL
        isArchiveScanning = true
        archiveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isArchiveScanning = false
                archiveTask = nil
            }
            do {
                let snapshot = try await archiveScanner.scan(root: root)
                try Task.checkCancellation()
                let currentRoot = URL(
                    fileURLWithPath: settings.downloadPath,
                    isDirectory: true
                ).standardizedFileURL.path
                guard currentRoot == root.path else { return }
                archiveSnapshot = snapshot
                try archiveStore.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                notice = "Could not scan the library: \(error.localizedDescription)"
            }
        }
    }

    func revealArchiveTrack(_ track: QobuzArchiveTrack) {
        guard let snapshot = archiveSnapshot else { return }
        let target = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true)
            .appendingPathComponent(track.relativePath)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: snapshot.rootPath, isDirectory: true)
            ])
        }
    }

    func libraryStatus(for item: NativeQueueItem) -> NativeLibraryStatus? {
        guard let snapshot = archiveSnapshot else { return nil }
        let coverage: QobuzArchiveCoverage
        switch item.request {
        case .track(let id):
            coverage = snapshot.coverage(trackID: id)
        case .album(let id):
            if let trackIDs = item.expectedTrackIDs, !trackIDs.isEmpty {
                coverage = snapshot.coverage(trackIDs: trackIDs, albumID: id)
            } else {
                coverage = snapshot.coverage(albumID: id)
            }
        case .playlist:
            guard let trackIDs = item.expectedTrackIDs, !trackIDs.isEmpty else { return nil }
            coverage = snapshot.coverage(trackIDs: trackIDs)
        case .artist:
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
        let trackIDs = album.tracks.filter(\.streamable).map(\.id)
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
        let trackIDs = tracks.filter(\.streamable).map(\.id)
        guard !trackIDs.isEmpty else { return nil }
        return NativeLibraryStatus(snapshot.coverage(trackIDs: trackIDs))
    }

    func browseCount(for category: NativeBrowseCategory) -> Int {
        switch category {
        case .albums: browseAlbums.count
        case .artists: browseArtists.count
        case .tracks: browseTracks.count
        }
    }

    func downloadSelected() {
        guard let selectedQueueID else { return }
        startDownloads(ids: [selectedQueueID])
    }

    func downloadAll() {
        startDownloads(ids: queue.filter { $0.status.canStart }.map(\.id))
    }

    func resume(_ activity: NativeDownloadActivity) {
        guard activity.status == .paused else { return }
        startDownloads(ids: [activity.queueID])
    }

    func repairArchiveTracks(_ tracks: [QobuzArchiveTrack]) {
        guard downloadTask == nil else {
            notice = "Wait for the current download to finish before starting repairs."
            return
        }
        guard credentials.isComplete else {
            notice = "Configure Qobuz credentials before repairing files."
            showSettings = true
            return
        }

        let unsupportedCount = tracks.count { track in
            track.integrity != .verified && QobuzQuality(formatID: track.formatID) == nil
        }
        let ids = stageArchiveRepairs(tracks)

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
            $0.integrity != .verified && QobuzQuality(formatID: $0.formatID) != nil
        }
        var ids: [UUID] = []
        var seenPaths = Set<String>()
        for target in repairable where seenPaths.insert(target.relativePath).inserted {
            if let index = queue.firstIndex(where: { $0.repairTarget?.relativePath == target.relativePath }) {
                guard queue[index].status != .downloading else { continue }
                queue[index].repairTarget = target
                queue[index].status = .ready
                ids.append(queue[index].id)
            } else {
                let item = NativeQueueItem(repairTarget: target)
                queue.append(item)
                ids.append(item.id)
            }
        }
        return ids
    }

    func cancelDownloads() {
        downloadTask?.cancel()
    }

    func clearFinishedActivities() {
        activities.removeAll { $0.status.isClearable }
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        sessionPersistenceTask?.cancel()
        markActiveDownloadsPaused(phase: "Paused after app closed")
        persistSessionNow(reportErrors: false)
        downloadTask?.cancel()
    }

    func reveal(_ activity: NativeDownloadActivity) {
        let target = activity.outputURL ?? URL(fileURLWithPath: settings.downloadPath, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func revealDownloadRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.downloadPath, isDirectory: true)])
    }

    private func configureClient() {
        client = credentials.isComplete ? clientFactory(credentials.coreValue) : nil
    }

    private func loadArchiveCache() {
        let rootPath = URL(
            fileURLWithPath: settings.downloadPath,
            isDirectory: true
        ).standardizedFileURL.path
        if let cached = try? archiveStore.load(), cached.rootPath == rootPath {
            archiveSnapshot = cached
        } else {
            archiveSnapshot = nil
        }
    }

    private func restoreSession() throws {
        guard var snapshot = try sessionStore.load() else { return }
        restoringSession = true
        defer { restoringSession = false }

        for index in snapshot.queue.indices {
            switch snapshot.queue[index].status {
            case .downloading:
                snapshot.queue[index].status = .paused
            case .loading:
                snapshot.queue[index].status = .ready
            default:
                break
            }
        }
        for index in snapshot.activities.indices where snapshot.activities[index].status.isActive {
            snapshot.activities[index].status = .paused
            snapshot.activities[index].phase = "Paused after interruption"
            snapshot.activities[index].bytesPerSecond = nil
        }
        queue = snapshot.queue
        activities = snapshot.activities
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
                    selectedQueueID: selectedQueueID
                )
            )
        } catch where reportErrors {
            notice = "Could not save the download queue: \(error.localizedDescription)"
        } catch {}
    }

    private func add(_ links: [ParsedQobuzLink]) {
        var firstID: UUID?
        for link in links {
            let item = NativeQueueItem(request: link.request)
            queue.append(item)
            firstID = firstID ?? item.id
        }
        selectQueueItem(firstID)
    }

    private func loadPreview(_ item: NativeQueueItem) {
        previewTask?.cancel()
        guard let client else {
            preview = .error("Configure Qobuz credentials to load metadata.")
            return
        }
        preview = .loading
        previewTask = Task { [weak self] in
            do {
                guard let self else { return }
                switch item.request {
                case .album(let id):
                    let value = try await client.album(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .album(value)
                    updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.artist.name, artworkURL: value.image?.bestURL)
                    updateQueue(item.id) { $0.expectedTrackIDs = value.tracks.filter(\.streamable).map(\.id) }
                case .track(let id):
                    let value = try await client.track(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .track(value)
                    updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.performer?.name ?? "Track", artworkURL: value.album?.image?.bestURL)
                case .playlist(let id):
                    let value = try await client.playlist(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .playlist(value)
                    updateQueueMetadata(item.id, title: value.name, subtitle: "\(value.tracks.count) tracks")
                    updateQueue(item.id) { $0.expectedTrackIDs = value.tracks.filter(\.streamable).map(\.id) }
                case .artist(let id):
                    let value = try await client.artist(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .artist(value)
                    let releaseCount = value.officialAlbums.count
                    updateQueueMetadata(
                        item.id,
                        title: value.name,
                        subtitle: "\(releaseCount) official \(releaseCount == 1 ? "release" : "releases")",
                        artworkURL: value.image?.bestURL
                    )
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                preview = .error(error.localizedDescription)
                updateQueue(item.id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    private func apply(_ results: QobuzSearchResults, category: NativeBrowseCategory) {
        switch category {
        case .albums: browseAlbums = results.albums
        case .artists: browseArtists = results.artists
        case .tracks: browseTracks = results.tracks
        }
        loadingBrowseCategories.remove(category)
        if loadingBrowseCategories.isEmpty, browseCategory == .albums, browseAlbums.isEmpty {
            if !browseArtists.isEmpty { browseCategory = .artists }
            else if !browseTracks.isEmpty { browseCategory = .tracks }
        }
    }

    private func startDownloads(ids: [UUID]) {
        guard downloadTask == nil, let client, credentials.isComplete else {
            if !credentials.isComplete { showSettings = true }
            return
        }
        let readyIDs = ids.filter { id in queue.first(where: { $0.id == id })?.status.canStart == true }
        guard !readyIDs.isEmpty else { return }
        let defaultQuality = settings.quality
        let defaultRootPath = settings.downloadPath

        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil }
            do {
                let validator = try FFmpegMediaValidator.bundled()
                let engine = NativeQobuzDownloadEngine(service: client, validator: validator)
                for id in readyIDs {
                    try Task.checkCancellation()
                    guard let item = queue.first(where: { $0.id == id }) else { continue }
                    let quality = item.downloadQuality
                        ?? item.repairTarget.flatMap { QobuzQuality(formatID: $0.formatID) }
                        ?? defaultQuality
                    let root = URL(
                        fileURLWithPath: item.downloadRootPath ?? defaultRootPath,
                        isDirectory: true
                    )
                    await runDownload(id: id, engine: engine, quality: quality, root: root)
                }
                refreshArchive()
            } catch is CancellationError {
                if isTerminating { markActiveDownloadsPaused(phase: "Paused after app closed") }
                else { markActiveDownloadsCancelled() }
            } catch NativeQobuzError.cancelled {
                if isTerminating { markActiveDownloadsPaused(phase: "Paused after app closed") }
                else { markActiveDownloadsCancelled() }
            } catch {
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
        updateQueue(queueID) {
            $0.status = .downloading
            $0.downloadQuality = quality
            $0.downloadRootPath = root.standardizedFileURL.path
        }
        let activityID: UUID
        if let index = activities.firstIndex(where: { $0.queueID == queueID && $0.status == .paused }) {
            activityID = activities[index].id
            activities[index].status = .queued
            activities[index].phase = "Resuming"
            activities[index].bytesPerSecond = nil
        } else {
            activityID = UUID()
            activities.insert(
                NativeDownloadActivity(id: activityID, queueID: queueID, title: item.title),
                at: 0
            )
        }
        persistSessionNow(reportErrors: false)
        do {
            let events = if let repairTarget = item.repairTarget {
                try engine.repairEvents(for: repairTarget, downloadRoot: root)
            } else {
                engine.events(for: item.request, quality: quality, downloadRoot: root)
            }
            for try await event in events {
                try Task.checkCancellation()
                reduce(event, activityID: activityID)
            }
            updateQueue(queueID) { $0.status = .completed }
        } catch is CancellationError {
            if isTerminating {
                updateQueue(queueID) { $0.status = .paused }
                updateActivity(activityID) { $0.status = .paused; $0.phase = "Paused after app closed" }
            } else {
                updateQueue(queueID) { $0.status = .cancelled }
                updateActivity(activityID) { $0.status = .cancelled; $0.phase = "Cancelled" }
            }
        } catch NativeQobuzError.cancelled {
            if isTerminating {
                updateQueue(queueID) { $0.status = .paused }
                updateActivity(activityID) { $0.status = .paused; $0.phase = "Paused after app closed" }
            } else {
                updateQueue(queueID) { $0.status = .cancelled }
                updateActivity(activityID) { $0.status = .cancelled; $0.phase = "Cancelled" }
            }
        } catch let error as NativeQobuzError where error.canResumeTransfer {
            updateQueue(queueID) { $0.status = .paused }
            updateActivity(activityID) {
                $0.status = .paused
                $0.phase = "Paused · \(error.localizedDescription)"
                $0.bytesPerSecond = nil
            }
        } catch {
            updateQueue(queueID) { $0.status = .failed(error.localizedDescription) }
            updateActivity(activityID) {
                $0.status = .failed(error.localizedDescription)
                $0.phase = error.localizedDescription
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
        updateActivity(activityID) { activity in
            switch event {
            case .resolving:
                activity.status = .resolving
                activity.phase = "Resolving Qobuz"
            case .planReady(let title, let count):
                activity.title = title
                activity.totalTracks = count
                activity.phase = "Preparing media"
            case .trackStarted(let track, let destination):
                activity.status = .downloading
                activity.phase = "Downloading"
                activity.currentTrack = track.track.displayTitle
                activity.outputURL = destination
                activity.bytesPerSecond = nil
            case .progress(let progress):
                activity.status = .downloading
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
                activity.status = .tagging
                activity.phase = "Writing metadata"
            case .validating:
                activity.status = .validating
                activity.phase = "Checking audio integrity"
            case .integrityVerified(_, let checksum):
                activity.checksum = checksum
                activity.phase = "Integrity verified"
            case .assetCreated(let url):
                activity.phase = "Created \(url.lastPathComponent)"
            case .warning(let message):
                activity.warnings.append(message)
                activity.phase = "Finishing with warnings"
            case .trackCompleted(_, let destination), .trackSkipped(_, let destination):
                activity.outputURL = destination
            case .completed:
                activity.status = .completed
                activity.phase = activity.warnings.isEmpty ? "Complete" : "Complete with warnings"
                activity.progress = 1
                activity.bytesPerSecond = nil
            }
        }
    }

    private func markActiveDownloadsCancelled() {
        for index in queue.indices where queue[index].status == .downloading { queue[index].status = .cancelled }
        for index in activities.indices where activities[index].status.isActive {
            activities[index].status = .cancelled
            activities[index].phase = "Cancelled"
        }
    }

    private func markActiveDownloadsPaused(phase: String) {
        for index in queue.indices where queue[index].status == .downloading {
            queue[index].status = .paused
        }
        for index in activities.indices where activities[index].status.isActive {
            activities[index].status = .paused
            activities[index].phase = phase
            activities[index].bytesPerSecond = nil
        }
    }

    private func updateQueue(_ id: UUID, mutate: (inout NativeQueueItem) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        mutate(&queue[index])
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
}
