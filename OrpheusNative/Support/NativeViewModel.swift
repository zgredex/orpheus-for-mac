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
    @Published private(set) var linkInbox: [NativeLinkInboxItem] = [] {
        didSet { scheduleSessionPersistence() }
    }
    @Published private(set) var settings: NativeSettings
    @Published private(set) var credentials = CredentialDraft()
    @Published private(set) var accountRegion = "??"
    @Published var notice: String?
    @Published var showSettings = false

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

    private let settingsStore: any NativeSettingsStoring
    private let dataMigrator: any NativeDataMigrating
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
    private var linkInboxTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var sessionPersistenceTask: Task<Void, Never>?
    private var lastProgressUpdate: [UUID: Date] = [:]
    private var started = false
    private var restoringSession = false
    private var isTerminating = false

    init(
        dataMigrator: any NativeDataMigrating = NoOpNativeDataMigrator(),
        settingsStore: any NativeSettingsStoring = NativeSettingsStore(),
        credentialStore: any NativeCredentialStoring = FileCredentialStore(),
        archiveStore: any NativeArchiveIndexStoring = NativeArchiveIndexStore(),
        sessionStore: (any NativeSessionStoring)? = nil,
        archiveScanner: any QobuzArchiveScanning = QobuzArchiveScanner(),
        clientFactory: @escaping (QobuzCredentials) -> any NativeQobuzServicing = {
            QobuzAPIClient(credentials: $0)
        }
    ) {
        self.dataMigrator = dataMigrator
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
        if browseResults.hasMoreResults,
           let reported = browseResults.reportedTotalCount,
           reported > loaded {
            return "\(loaded) of \(reported) loaded"
        }
        return loaded == 1 ? "1 result" : "\(loaded) results"
    }

    var browseAlbums: [QobuzAlbumSummary] { browseResults.albums }
    var browseArtists: [QobuzArtist] { browseResults.artists }
    var browsePlaylists: [QobuzPlaylist] { browseResults.playlists }
    var browseTracks: [QobuzTrack] { browseResults.tracks }

    var regionDisplay: String {
        guard let flag = CountryFlag.emoji(for: accountRegion) else { return accountRegion }
        return "\(flag) \(accountRegion.uppercased())"
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try dataMigrator.migrateIfNeeded()
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
        let extraction = QobuzLinkParser.extract(from: value)
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
        do { addText(try String(contentsOf: url, encoding: .utf8)) }
        catch { notice = "Could not read the text file: \(error.localizedDescription)" }
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
            notice = "That Qobuz item is already queued."
            return
        }
        var item = NativeQueueItem(request: request, title: title)
        if let subtitle { item.subtitle = subtitle }
        item.artworkURL = artworkURL
        queue.append(item)
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

        for category in NativeBrowseCategory.allCases {
            browseTasks.append(Task { [weak self] in
                do {
                    let results = try await client.search(
                        query,
                        category: category.coreValue,
                        limit: 30,
                        offset: 0
                    )
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
                let content: BrowsePageContent
                let availability: NativeBrowseAvailability
                switch destination {
                case .album(let id):
                    let value = try await client.album(id: id)
                    content = .album(value)
                    availability = self?.availability(for: value) ?? .checking
                case .artist(let id):
                    let value = try await client.artist(id: id)
                    content = .artist(value)
                    availability = self?.availability(for: value) ?? .checking
                case .track(let id):
                    let value = try await client.track(id: id)
                    content = .track(value)
                    availability = self?.availability(for: value) ?? .checking
                case .playlist(let id):
                    let value = try await client.playlist(id: id)
                    content = .playlist(value)
                    availability = self?.availability(for: value) ?? .checking
                case .label(let id):
                    let value = try await client.label(id: id)
                    content = .label(value)
                    availability = self?.availability(for: value) ?? .checking
                }
                guard let self, !Task.isCancelled else { return }
                updateBrowsePage(page.id, content: content, availability: availability)
            } catch {
                guard let self, !Task.isCancelled else { return }
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
        accountRegion == "??" ? "this Qobuz account" : "the \(regionDisplay) account"
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

    func revealArchiveEntry(_ entry: QobuzArchiveEntry) {
        guard let snapshot = archiveSnapshot else { return }
        let root = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true).standardizedFileURL
        let target = root.appendingPathComponent(entry.relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPrefix), FileManager.default.fileExists(atPath: target.path) else {
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
            if let trackIDs = item.expectedTrackIDs, !trackIDs.isEmpty {
                coverage = snapshot.coverage(trackIDs: trackIDs, albumID: id)
            } else {
                coverage = snapshot.coverage(albumID: id)
            }
        case .playlist:
            guard let trackIDs = item.expectedTrackIDs, !trackIDs.isEmpty else { return nil }
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
        if let total = browseResults.total(for: category), total > loaded {
            return "\(loaded)/\(total)"
        }
        return String(loaded)
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
        let task = Task { [weak self] in
            do {
                let results = try await client.search(
                    query,
                    category: category.coreValue,
                    limit: 30,
                    offset: offset
                )
                guard let self,
                      self.browseRequestID == requestID,
                      self.browseQuery == query,
                      !Task.isCancelled else { return }
                self.browseResults.append(results, for: category)
                self.loadingMoreBrowseCategories.remove(category)
            } catch {
                guard let self,
                      self.browseRequestID == requestID,
                      self.browseQuery == query,
                      !Task.isCancelled else { return }
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
        linkInboxTask?.cancel()
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
                    selectedQueueID: selectedQueueID,
                    linkInbox: linkInbox
                )
            )
        } catch where reportErrors {
            notice = "Could not save the download queue: \(error.localizedDescription)"
        } catch {}
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
                    updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.albumArtistDisplayName, artworkURL: value.image?.bestURL)
                    updateQueue(item.id) { $0.expectedTrackIDs = value.availableTracks.map(\.id) }
                case .track(let id):
                    let value = try await client.track(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .track(value)
                    updateQueueMetadata(item.id, title: value.displayTitle, subtitle: value.performer?.name ?? "Track", artworkURL: value.album?.image?.bestURL)
                case .playlist(let id):
                    let value = try await client.playlist(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .playlist(value)
                    updateQueueMetadata(
                        item.id,
                        title: value.name,
                        subtitle: [value.owner?.name, "\(value.availableTracks.count) available tracks"]
                            .compactMap { $0 }.joined(separator: " · "),
                        artworkURL: value.artworkURL
                    )
                    updateQueue(item.id) { $0.expectedTrackIDs = value.availableTracks.map(\.id) }
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
                case .label(let id):
                    let value = try await client.label(id: id)
                    guard !Task.isCancelled else { return }
                    preview = .label(value)
                    let albumCount = value.availableAlbums.count
                    updateQueueMetadata(
                        item.id,
                        title: value.name,
                        subtitle: "\(albumCount) available \(albumCount == 1 ? "album" : "albums")"
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
        browseResults.replace(results, for: category)
        loadingBrowseCategories.remove(category)
        if loadingBrowseCategories.isEmpty, browseCategory == .albums, browseAlbums.isEmpty {
            browseCategory = browseResults.firstNonemptyCategory ?? .albums
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
            activities[index].quality = quality
            activities[index].bytesPerSecond = nil
        } else {
            activityID = UUID()
            activities.insert(
                NativeDownloadActivity(
                    id: activityID,
                    queueID: queueID,
                    title: item.title,
                    quality: quality
                ),
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
