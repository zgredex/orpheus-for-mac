import AppKit
import Foundation
import NativeQobuzCore

protocol NativeQobuzServicing: QobuzCatalogService, QobuzBrowsingService {}
extension QobuzAPIClient: NativeQobuzServicing {}

@MainActor
final class NativeViewModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var queue: [NativeQueueItem] = []
    @Published var selectedQueueID: UUID?
    @Published private(set) var preview: NativePreviewState = .empty
    @Published private(set) var activities: [NativeDownloadActivity] = []
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

    private let settingsStore: any NativeSettingsStoring
    private let credentialStore: any NativeCredentialStoring
    private let clientFactory: (QobuzCredentials) -> any NativeQobuzServicing
    private var client: (any NativeQobuzServicing)?
    private var previewTask: Task<Void, Never>?
    private var browseTasks: [Task<Void, Never>] = []
    private var browseRequestID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var started = false

    init(
        settingsStore: any NativeSettingsStoring = NativeSettingsStore(),
        credentialStore: any NativeCredentialStoring = KeychainCredentialStore(),
        clientFactory: @escaping (QobuzCredentials) -> any NativeQobuzServicing = {
            QobuzAPIClient(credentials: $0)
        }
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
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
    var canClearActivity: Bool { activities.contains { !$0.status.isActive } }
    var isBrowseLoading: Bool { !loadingBrowseCategories.isEmpty }

    var browseStatusText: String {
        if isBrowseLoading {
            return "Searching all categories"
        }
        let total = browseAlbums.count + browseArtists.count + browseTracks.count
        return total == 1 ? "1 result" : "\(total) results"
    }

    var regionDisplay: String {
        guard accountRegion.count == 2 else { return accountRegion }
        let flag = accountRegion.uppercased().unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard let value = UnicodeScalar(127397 + scalar.value) else { return nil }
            return value
        }.map(String.init).joined()
        return flag.isEmpty ? accountRegion : "\(flag) \(accountRegion.uppercased())"
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            settings = try settingsStore.load()
            credentials = try credentialStore.load() ?? CredentialDraft()
            configureClient()
            if credentials.isComplete {
                Task { await testConnection(showSuccess: false) }
            } else {
                showSettings = true
            }
        } catch {
            notice = "Could not load native settings: \(error.localizedDescription)"
            showSettings = true
        }
    }

    func saveConfiguration(credentials: CredentialDraft, settings: NativeSettings) throws {
        guard !isDownloading else { throw NativeQobuzError.unavailable("Settings cannot change during a download.") }
        try settingsStore.save(settings)
        try credentialStore.save(credentials)
        self.settings = settings
        self.credentials = credentials
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

    func addRequest(_ request: QobuzRequest, title: String? = nil) {
        guard !queue.contains(where: { $0.canonicalURL == request.canonicalURL }) else {
            notice = "That Qobuz item is already queued."
            return
        }
        let item = NativeQueueItem(request: request, title: title)
        queue.append(item)
        selectQueueItem(item.id)
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
        isBrowseOpen = false
    }

    func retryBrowseSearch() {
        guard !browseQuery.isEmpty else { return }
        let category = browseCategory
        search(browseQuery)
        browseCategory = category
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

    func cancelDownloads() {
        downloadTask?.cancel()
    }

    func clearFinishedActivities() {
        activities.removeAll { !$0.status.isActive }
    }

    func reveal(_ activity: NativeDownloadActivity) {
        let target = activity.outputURL ?? URL(fileURLWithPath: settings.downloadPath, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func configureClient() {
        client = credentials.isComplete ? clientFactory(credentials.coreValue) : nil
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
                    updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.artist.name)
                case .track(let id):
                    let value = try await client.track(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .track(value)
                    updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.performer?.name ?? "Track")
                case .playlist(let id):
                    let value = try await client.playlist(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .playlist(value)
                    updateQueueMetadata(item.id, title: value.name, subtitle: "\(value.tracks.count) tracks")
                case .artist(let id):
                    let value = try await client.artist(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .artist(value)
                    updateQueueMetadata(item.id, title: value.name, subtitle: "\(value.albums.count) albums")
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
        let quality = settings.quality
        let root = URL(fileURLWithPath: settings.downloadPath, isDirectory: true)

        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil }
            do {
                let validator = try FFmpegMediaValidator.bundled()
                let engine = NativeQobuzDownloadEngine(service: client, validator: validator)
                for id in readyIDs {
                    try Task.checkCancellation()
                    await runDownload(id: id, engine: engine, quality: quality, root: root)
                }
            } catch is CancellationError {
                markActiveDownloadsCancelled()
            } catch NativeQobuzError.cancelled {
                markActiveDownloadsCancelled()
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
        updateQueue(queueID) { $0.status = .downloading }
        let activityID = UUID()
        activities.insert(
            NativeDownloadActivity(id: activityID, queueID: queueID, title: item.title),
            at: 0
        )
        do {
            for try await event in engine.events(for: item.request, quality: quality, downloadRoot: root) {
                try Task.checkCancellation()
                reduce(event, activityID: activityID)
            }
            updateQueue(queueID) { $0.status = .completed }
        } catch is CancellationError {
            updateQueue(queueID) { $0.status = .cancelled }
            updateActivity(activityID) { $0.status = .cancelled; $0.phase = "Cancelled" }
        } catch NativeQobuzError.cancelled {
            updateQueue(queueID) { $0.status = .cancelled }
            updateActivity(activityID) { $0.status = .cancelled; $0.phase = "Cancelled" }
        } catch {
            updateQueue(queueID) { $0.status = .failed(error.localizedDescription) }
            updateActivity(activityID) {
                $0.status = .failed(error.localizedDescription)
                $0.phase = error.localizedDescription
            }
        }
    }

    private func reduce(_ event: QobuzDownloadEvent, activityID: UUID) {
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
            case .progress(let progress):
                activity.status = .downloading
                activity.progress = progress.overallFraction
                activity.completedTracks = progress.completedTracks
                activity.totalTracks = progress.totalTracks
                activity.bytesWritten = progress.bytesWritten
                activity.totalBytes = progress.totalBytes
                activity.bytesPerSecond = progress.bytesPerSecond
            case .tagging:
                activity.status = .tagging
                activity.phase = "Writing metadata"
                activity.bytesPerSecond = nil
            case .validating:
                activity.status = .validating
                activity.phase = "Checking audio integrity"
                activity.bytesPerSecond = nil
            case .integrityVerified(_, let checksum):
                activity.checksum = checksum
                activity.phase = "Integrity verified"
            case .assetCreated(let url):
                activity.phase = "Created \(url.lastPathComponent)"
            case .trackCompleted(_, let destination), .trackSkipped(_, let destination):
                activity.outputURL = destination
            case .completed:
                activity.status = .completed
                activity.phase = "Complete"
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

    private func updateQueue(_ id: UUID, mutate: (inout NativeQueueItem) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        mutate(&queue[index])
    }

    private func updateQueueMetadata(_ id: UUID, title: String, subtitle: String) {
        updateQueue(id) { item in
            item.title = title
            item.subtitle = subtitle
        }
    }

    private func updateActivity(_ id: UUID, mutate: (inout NativeDownloadActivity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        mutate(&activities[index])
    }
}
