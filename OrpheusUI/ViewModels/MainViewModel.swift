import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MainViewModel: ObservableObject {
    @Published var linkInput: String = ""
    @Published var batchInput: String = ""
    @Published var showBatchInput = false
    @Published var queuedLinks: [QueuedLink] = []
    @Published var selectedQueueID: UUID?
    @Published var queueNotice: String?
    @Published var previewState: PreviewState = .idle
    @Published var downloads: [DownloadItem] = []
    @Published var selectedQuality: String = "hifi"
    @Published var showSettings = false
    @Published var settings: SettingsDocument?
    @Published var accountRegion: String = "??"
    @Published var isPreflighting = false
    @Published var settingsLoadFailed = false

    @Published var selectedBrowseCategory: BrowseCategory = .albums
    @Published var browseQuery: String = ""
    @Published var browseResults: BrowseResults = .empty
    @Published var browseRoute: BrowseRoute = .idle
    private var browseBackStack: [BrowseRoute] = []
    private var browseRequestID: UUID?
    private var browseTasks: [BrowseCategory: Task<Void, Never>] = [:]
    private var browseCategoryWasManuallySelected = false
    private var detailTask: Task<Void, Never>?

    private let runtime: RuntimeLocator
    private let finderRevealer: any FinderRevealing
    private let outputResolver: DownloadOutputResolver
    private var qobuzAPI: QobuzServicing?
    private var previewTask: Task<Void, Never>?
    private var preflightTask: Task<Void, Never>?
    private var activeDownloadTask: Task<Void, Never>?
    private var runners: [UUID: OrpheusRunner] = [:]
    private var activeDownloadID: UUID?
    private var activeQueueID: UUID?
    private let validDownloadQualities = Set(["hifi", "lossless", "high"])

    init(
        runtime: RuntimeLocator = RuntimeLocator(),
        qobuzAPI: QobuzServicing? = nil,
        finderRevealer: any FinderRevealing = WorkspaceFinderRevealer(),
        outputResolver: DownloadOutputResolver? = nil
    ) {
        self.runtime = runtime
        self.qobuzAPI = qobuzAPI
        self.finderRevealer = finderRevealer
        self.outputResolver = outputResolver ?? DownloadOutputResolver(fileManager: runtime.fileManager)
    }

    var downloadPath: String {
        runtime.resolvedDownloadURL(from: settings?.downloadPath ?? "").path
    }

    var accountRegionDisplay: String {
        RegionDisplay.display(accountRegion)
    }

    func resolvedDownloadPath(for rawPath: String) -> String {
        runtime.resolvedDownloadURL(from: rawPath).path
    }

    var runtimePath: String {
        runtime.runtimeProjectURL.path
    }

    var selectedQueueItem: QueuedLink? {
        guard let selectedQueueID else { return nil }
        return queuedLinks.first { $0.id == selectedQueueID }
    }

    var isDownloadRunning: Bool {
        activeDownloadTask != nil
    }

    var canDownloadSelected: Bool {
        guard !isDownloadRunning,
              !isPreflighting,
              let item = selectedQueueItem,
              item.state.canStart,
              item.parsed.downloadableURL != nil else {
            return false
        }
        return true
    }

    var canDownloadAll: Bool {
        !isDownloadRunning
            && !isPreflighting
            && queuedLinks.contains { $0.state.canStart && $0.parsed.downloadableURL != nil }
    }

    var canCancelDownloads: Bool {
        isPreflighting || isDownloadRunning || downloads.contains { $0.status.isActive }
    }

    var canClearFinishedDownloads: Bool {
        downloads.contains { $0.status.isClearable }
    }

    var selectedDownloadActionTitle: String {
        selectedQueueItem?.parsed.downloadActionTitle ?? "Download Selected"
    }

    var queueStatusSummary: String {
        guard !queuedLinks.isEmpty else { return "Queue empty" }

        let active = queuedLinks.filter(\.state.isActive).count
        let ready = queuedLinks.filter { $0.state.canStart && $0.parsed.downloadableURL != nil }.count
        let done = queuedLinks.filter {
            if case .completed = $0.state { return true }
            return false
        }.count
        let failed = queuedLinks.filter {
            if case .failed = $0.state { return true }
            if case .invalid = $0.state { return true }
            return false
        }.count

        var parts = ["\(queuedLinks.count) queued"]
        if ready > 0 { parts.append("\(ready) ready") }
        if active > 0 { parts.append("\(active) active") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) needs attention") }
        return parts.joined(separator: " / ")
    }

    var downloadStatusSummary: String {
        guard !downloads.isEmpty else { return "No downloads yet" }

        let active = downloads.filter { $0.status.isActive }.count
        let done = downloads.filter { $0.status == .completed }.count
        let failed = downloads.filter {
            if case .failed = $0.status { return true }
            return false
        }.count

        var parts: [String] = []
        if active > 0 { parts.append("\(active) running") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "\(downloads.count) downloads" : parts.joined(separator: " / ")
    }

    var isBrowseActive: Bool {
        browseRoute.isActive
    }

    var canBrowseBack: Bool {
        !browseBackStack.isEmpty
    }

    var browseCountSummary: String {
        BrowseCategory.allCases
            .map { "\($0.shortLabel) \(browseResults.count(for: $0))" }
            .joined(separator: " / ")
    }

    func loadSettings() {
        do {
            try runtime.prepareRuntime()
            let document = try SettingsStore.load(from: runtime.settingsURL)
            settings = document
            settingsLoadFailed = false
            selectedQuality = document.downloadQuality.isEmpty ? "hifi" : document.downloadQuality
            configureQobuzAPI(from: document)
        } catch {
            settingsLoadFailed = true
            settings = nil
            qobuzAPI = nil
            previewState = .error(error.localizedDescription)
        }
    }

    func addLinkInput() {
        let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = QobuzURLParser.parse(trimmed)
        if parsed != .invalid {
            addLinks(from: linkInput)
            linkInput = ""
            browseRoute = .idle
        } else if !trimmed.isEmpty {
            performSearch()
        }
    }

    func submitInput() {
        if !linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLinkInput()
        }
    }

    func addLinkInputDirect(_ url: String) {
        linkInput = url
        let parsed = QobuzURLParser.parse(url)
        if parsed != .invalid {
            addLinks(from: url)
            linkInput = ""
        }
    }

    func addLinksFromInput() {
        addLinks(from: batchInput)
    }

    func clearLinkInput() {
        linkInput = ""
    }

    func clearInput() {
        batchInput = ""
    }

    // MARK: - Browse

    func performSearch() {
        let query = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        cancelBrowseWork()
        let requestID = UUID()
        browseRequestID = requestID
        browseQuery = query
        selectedBrowseCategory = .albums
        browseCategoryWasManuallySelected = false
        browseResults = .loadingAll()
        browseBackStack.removeAll()
        browseRoute = .results
        linkInput = ""

        for category in BrowseCategory.allCases {
            loadBrowseCategory(category, query: query, requestID: requestID)
        }
    }

    func selectBrowseCategory(_ category: BrowseCategory) {
        browseCategoryWasManuallySelected = true
        selectedBrowseCategory = category
    }

    func pushArtist(_ artistID: String, name: String) {
        guard !artistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            queueNotice = "Cannot open artist: missing Qobuz artist ID."
            return
        }

        detailTask?.cancel()
        browseBackStack.append(browseRoute)
        browseRoute = .loading

        detailTask = Task { [weak self] in
            guard let self else { return }
            guard let api = qobuzAPI else {
                restoreBrowseAfterDetailFailure()
                return
            }
            do {
                let artist = try await api.getArtist(id: artistID)
                guard !Task.isCancelled else { return }
                let resolvedName = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? name
                    : artist.name
                browseRoute = .artistDetail(
                    artist: QobuzSearchArtist(id: artist.id ?? FlexibleID(artistID), name: resolvedName, image: artist.image),
                    albums: (artist.albums?.items ?? []).filter(\.isBrowseAvailable)
                )
            } catch {
                guard !Task.isCancelled else { return }
                restoreBrowseAfterDetailFailure()
                queueNotice = "Could not load artist: \(error.localizedDescription)"
            }
        }
    }

    func pushAlbum(_ album: QobuzAlbumResponse) {
        if let reason = album.browseUnavailableReason {
            browseBackStack.append(browseRoute)
            browseRoute = .error(reason)
            return
        }

        detailTask?.cancel()
        browseBackStack.append(browseRoute)
        browseRoute = .loading

        detailTask = Task { [weak self] in
            guard let self else { return }
            guard let api = qobuzAPI else {
                restoreBrowseAfterDetailFailure()
                queueNotice = QobuzError.missingCredentials.localizedDescription
                return
            }
            do {
                let fullAlbum = try await api.getAlbum(id: album.id.value)
                guard !Task.isCancelled else { return }
                showAlbumDetail(fullAlbum)
            } catch {
                guard !Task.isCancelled else { return }
                restoreBrowseAfterDetailFailure()
                queueNotice = "Could not load album tracks: \(error.localizedDescription)"
            }
        }
    }

    func pushAlbumFromTrack(_ track: QobuzTrackResponse) {
        detailTask?.cancel()
        browseBackStack.append(browseRoute)
        browseRoute = .loading

        detailTask = Task { [weak self] in
            guard let self else { return }
            guard let api = qobuzAPI else {
                restoreBrowseAfterDetailFailure()
                return
            }
            do {
                let album = try await api.getAlbum(id: track.album.id.value)
                guard !Task.isCancelled else { return }
                showAlbumDetail(album)
            } catch {
                guard !Task.isCancelled else { return }
                restoreBrowseAfterDetailFailure()
                queueNotice = "Could not load album: \(error.localizedDescription)"
            }
        }
    }

    func pushArtistFromAlbum(_ artistID: String, name: String) {
        pushArtist(artistID, name: name)
    }

    func browseBack() {
        detailTask?.cancel()
        browseRoute = browseBackStack.popLast() ?? .results
    }

    func dismissBrowse() {
        cancelBrowseWork()
        browseRoute = .idle
        browseBackStack.removeAll()
    }

    func addAlbumToQueue(_ albumID: String) {
        addQueueURL("https://open.qobuz.com/album/\(albumID)")
    }

    func addTrackToQueue(_ trackID: String) {
        addQueueURL("https://open.qobuz.com/track/\(trackID)")
    }

    func addArtistToQueue(_ artistID: String) {
        addQueueURL("https://open.qobuz.com/artist/\(artistID)")
    }

    func addAllArtistAlbums(_ albums: [QobuzAlbumResponse]) {
        let urls = albums
            .map { "https://open.qobuz.com/album/\($0.id.value)" }
            .joined(separator: "\n")
        addLinks(from: urls)
    }

    func downloadAlbumNow(_ albumID: String) {
        if let id = addQueueURL("https://open.qobuz.com/album/\(albumID)") {
            selectedQueueID = id
        }
        downloadSelected()
    }

    func downloadTrackNow(_ trackID: String) {
        if let id = addQueueURL("https://open.qobuz.com/track/\(trackID)") {
            selectedQueueID = id
        }
        downloadSelected()
    }

    func downloadArtistNow(_ artistID: String) {
        if let id = addQueueURL("https://open.qobuz.com/artist/\(artistID)") {
            selectedQueueID = id
        }
        downloadSelected()
    }

    private func loadBrowseCategory(_ category: BrowseCategory, query: String, requestID: UUID) {
        browseTasks[category]?.cancel()
        browseTasks[category] = Task { [weak self] in
            guard let self else { return }
            guard let api = qobuzAPI else {
                updateBrowseResults(requestID: requestID, category: category) { result in
                    result.fail("Missing Qobuz credentials.")
                }
                return
            }

            do {
                let response = try await api.search(query: query, type: category.searchType, limit: 30)
                let albumResolution = category == .albums
                    ? await resolveBrowseAlbums(response.albums?.items ?? [], query: query, api: api)
                    : nil
                guard !Task.isCancelled else { return }
                updateBrowseResults(requestID: requestID, category: category) { result in
                    switch category {
                    case .albums:
                        result.albums = albumResolution?.albums ?? []
                        result.unavailableCount = albumResolution?.unavailableCount ?? 0
                    case .artists:
                        result.artists = response.artists?.items ?? []
                        result.unavailableCount = 0
                    case .tracks:
                        let tracks = response.tracks?.items ?? []
                        result.tracks = tracks.filter(\.isBrowseAvailable)
                        result.unavailableCount = tracks.count - result.tracks.count
                    }
                    result.load()
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateBrowseResults(requestID: requestID, category: category) { result in
                    result.fail(error.localizedDescription)
                }
            }
        }
    }

    private func updateBrowseResults(
        requestID: UUID,
        category: BrowseCategory,
        _ update: (inout BrowseCategoryResult) -> Void
    ) {
        guard browseRequestID == requestID else { return }
        update(&browseResults[category])
        autoSelectBrowseCategoryIfNeeded()
    }

    private func autoSelectBrowseCategoryIfNeeded() {
        guard !browseCategoryWasManuallySelected,
              case .results = browseRoute else {
            return
        }

        let selectedResult = browseResults[selectedBrowseCategory]
        guard selectedResult.count == 0 else { return }

        if let categoryWithResults = BrowseCategory.allCases.first(where: { category in
            browseResults[category].count > 0
        }) {
            selectedBrowseCategory = categoryWithResults
        }
    }

    private func resolveBrowseAlbums(
        _ albums: [QobuzAlbumResponse],
        query: String,
        api: QobuzServicing
    ) async -> BrowseAlbumResolution {
        var resolved: [QobuzAlbumResponse] = []
        var seenIDs = Set<String>()
        var unresolvedUnavailableCount = 0
        var trackCandidates: [QobuzTrackResponse]?

        for album in albums {
            if album.isBrowseAvailable {
                appendBrowseAlbum(album, to: &resolved, seenIDs: &seenIDs)
                continue
            }

            if trackCandidates == nil {
                trackCandidates = (try? await api.search(query: query, type: .track, limit: 30).tracks?.items) ?? []
            }

            if let equivalent = await resolveAvailableEquivalent(
                for: album,
                trackCandidates: trackCandidates ?? [],
                api: api
            ) {
                appendBrowseAlbum(equivalent, to: &resolved, seenIDs: &seenIDs)
            } else {
                unresolvedUnavailableCount += 1
            }
        }

        return BrowseAlbumResolution(albums: resolved, unavailableCount: unresolvedUnavailableCount)
    }

    private func resolveAvailableEquivalent(
        for unavailableAlbum: QobuzAlbumResponse,
        trackCandidates: [QobuzTrackResponse],
        api: QobuzServicing
    ) async -> QobuzAlbumResponse? {
        guard let match = trackCandidates.first(where: { track in
            track.isBrowseAvailable && trackMatches(album: unavailableAlbum, track: track)
        }) else {
            return nil
        }

        guard let album = try? await api.getAlbum(id: match.album.id.value),
              album.isBrowseAvailable,
              album.tracks?.items.isEmpty == false else {
            return nil
        }
        return album
    }

    private func trackMatches(album: QobuzAlbumResponse, track: QobuzTrackResponse) -> Bool {
        let targetTitle = normalizedBrowseMatch(album.title)
        let candidateTitle = normalizedBrowseMatch(track.album.title)
        guard targetTitle == candidateTitle else { return false }

        let targetArtist = normalizedBrowseMatch(album.artist.name)
        let candidateArtists = [
            track.performer?.name,
            track.album.artist?.name
        ]
            .compactMap { $0 }
            .map(normalizedBrowseMatch)
            .filter { !$0.isEmpty }

        return candidateArtists.contains(targetArtist)
    }

    private func appendBrowseAlbum(
        _ album: QobuzAlbumResponse,
        to albums: inout [QobuzAlbumResponse],
        seenIDs: inout Set<String>
    ) {
        guard !seenIDs.contains(album.id.value) else { return }
        seenIDs.insert(album.id.value)
        albums.append(album)
    }

    private func normalizedBrowseMatch(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showAlbumDetail(_ album: QobuzAlbumResponse) {
        let preview = AlbumPreviewInfo(from: album)
        let tracks = album.tracks?.items ?? []
        browseRoute = .albumDetail(album: preview, tracks: tracks)
    }

    private func restoreBrowseAfterDetailFailure() {
        browseRoute = browseBackStack.popLast() ?? .results
    }

    @discardableResult
    private func addQueueURL(_ url: String) -> UUID? {
        let parsed = QobuzURLParser.parse(url)
        guard let canonical = parsed.downloadableURL else {
            queueNotice = "Cannot add item: missing Qobuz ID."
            return nil
        }

        if let existing = queuedLinks.first(where: { $0.canonicalURL == canonical }) {
            selectedQueueID = existing.id
            selectedQueueItemChanged()
            queueNotice = "Already in queue."
            return existing.id
        }

        let before = Set(queuedLinks.map(\.id))
        addLinkInputDirect(url)
        return queuedLinks.first { !before.contains($0.id) }?.id
    }

    private func cancelBrowseWork() {
        detailTask?.cancel()
        detailTask = nil
        for task in browseTasks.values {
            task.cancel()
        }
        browseTasks.removeAll()
    }

    func toggleBatchInput() {
        showBatchInput.toggle()
    }

    func importTextFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"

        var contentTypes: [UTType] = [.plainText]
        if let m3u = UTType(filenameExtension: "m3u") { contentTypes.append(m3u) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { contentTypes.append(m3u8) }
        panel.allowedContentTypes = contentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: url, usedEncoding: &encoding)
            addLinks(from: text)
        } catch {
            queueNotice = "Could not import file: \(error.localizedDescription)"
        }
    }

    func clearQueue() {
        let removableCount = queuedLinks.filter { !$0.state.isActive }.count
        guard removableCount > 0 else {
            queueNotice = queuedLinks.isEmpty
                ? "Queue is already empty."
                : "No finished or waiting queue rows to clear."
            return
        }

        let selectedWasRemoved = selectedQueueID.map { selected in
            queuedLinks.contains { $0.id == selected && !$0.state.isActive }
        } ?? false

        queuedLinks.removeAll { !$0.state.isActive }

        if selectedWasRemoved || selectedQueueID == nil {
            selectedQueueID = queuedLinks.first?.id
            selectedQueueItemChanged()
        }

        queueNotice = queuedLinks.isEmpty
            ? "Queue cleared."
            : "Cleared \(removableCount) \(removableCount == 1 ? "queue row" : "queue rows")."
    }

    func removeQueueItem(id: UUID) {
        if queuedLinks.first(where: { $0.id == id })?.state.isActive == true {
            cancelActiveDownload()
        }

        queuedLinks.removeAll { $0.id == id }

        if selectedQueueID == id {
            selectedQueueID = queuedLinks.first?.id
            selectedQueueItemChanged()
        }
    }

    func selectedQueueItemChanged() {
        previewTask?.cancel()

        guard let item = selectedQueueItem else {
            previewState = queuedLinks.isEmpty ? .idle : .idle
            return
        }

        if case .invalid(let message) = item.state {
            previewState = .error(message)
            return
        }

        if let cached = item.cachedPreview {
            previewState = cached
            return
        }

        previewTask = Task { [weak self, itemID = item.id] in
            await self?.fetchPreview(for: itemID)
        }
    }

    func openSettings() {
        showSettings = true
    }

    func selectedQualityChanged() {
        settings?.downloadQuality = selectedQuality
        saveSettings(reload: false)
    }

    func startDownload() {
        downloadSelected()
    }

    func downloadSelected() {
        if !linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLinkInput()
        } else if selectedQueueID == nil, !batchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLinksFromInput()
        }

        guard let selectedQueueID,
              let item = queuedLinks.first(where: { $0.id == selectedQueueID }),
              item.state.canStart,
              item.parsed.downloadableURL != nil else {
            queueNotice = "Select a ready Qobuz link to download."
            return
        }

        startQueuedDownloads(ids: [selectedQueueID])
    }

    func downloadAllQueued() {
        if !linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLinkInput()
        } else if queuedLinks.isEmpty, !batchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLinksFromInput()
        }

        let ids = queuedLinks
            .filter { $0.state.canStart && $0.parsed.downloadableURL != nil }
            .map(\.id)

        guard !ids.isEmpty else {
            queueNotice = "No ready links to download."
            return
        }

        startQueuedDownloads(ids: ids)
    }

    func cancelDownload(id: UUID) {
        guard id == activeDownloadID else { return }
        cancelActiveDownload()
    }

    func cancelAllDownloads() {
        cancelPreflight()
        cancelActiveDownload()

        for index in queuedLinks.indices where queuedLinks[index].state == .queued {
            queuedLinks[index].state = .ready
        }
    }

    func revealInFinder(id: UUID) {
        guard let item = downloads.first(where: { $0.id == id }),
              case .completed = item.status else {
            return
        }

        let root = runtime.resolvedDownloadURL(from: settings?.downloadPath ?? "")
        finderRevealer.reveal(urls: [item.resolvedOutputURL ?? root])
    }

    func removeDownload(id: UUID) {
        if id == activeDownloadID {
            cancelActiveDownload()
        }

        downloads.removeAll { $0.id == id }
    }

    func clearDownloads() {
        downloads.removeAll { $0.status.isClearable }
    }

    func testConnection(appID: String, appSecret: String, authToken: String) async -> Result<String, Error> {
        let api = QobuzAPI(appID: appID, appSecret: appSecret, authToken: authToken)
        do {
            let region = try await api.validateAccount()
            return .success(region)
        } catch {
            return .failure(error)
        }
    }

    func applySettings(
        appID: String,
        appSecret: String,
        authToken: String,
        userID: String,
        downloadPath: String,
        quality: String
    ) {
        guard settings != nil else { return }
        guard !isPreflighting, !isDownloadRunning else {
            queueNotice = "Wait for the current download check or download to finish before changing Settings."
            return
        }
        let trimmedQuality = quality.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.qobuzAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.qobuzAppSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.qobuzAuthToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.qobuzUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.downloadPath = downloadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.downloadQuality = trimmedQuality.isEmpty ? "hifi" : trimmedQuality
        selectedQuality = settings?.downloadQuality ?? "hifi"
        saveSettings(reload: true)
    }

    private func addLinks(from text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            queueNotice = "No links found."
            return
        }

        let known = Set(queuedLinks.compactMap { $0.parsed.downloadableURL })
        let extraction = QobuzLinkExtractor.extract(from: text, knownCanonicalURLs: known)
        var newValidIDs: [UUID] = []
        var newInvalidIDs: [UUID] = []

        for link in extraction.links {
            let item = QueuedLink(
                originalURL: link.originalURL,
                canonicalURL: link.canonicalURL,
                parsed: link.parsed,
                title: nil,
                subtitle: link.canonicalURL,
                coverURL: nil,
                state: .ready,
                cachedPreview: nil,
                downloadID: nil
            )
            queuedLinks.append(item)
            newValidIDs.append(item.id)
        }

        for invalidURL in extraction.invalidQobuzURLs {
            let item = QueuedLink.invalid(url: invalidURL)
            queuedLinks.append(item)
            newInvalidIDs.append(item.id)
        }

        if let firstID = newValidIDs.first {
            selectedQueueID = firstID
            selectedQueueItemChanged()
        } else if selectedQueueID == nil, let firstInvalid = newInvalidIDs.first {
            selectedQueueID = firstInvalid
            selectedQueueItemChanged()
        }

        queueNotice = linkNotice(
            added: newValidIDs.count,
            invalid: extraction.invalidQobuzURLs.count,
            duplicates: extraction.duplicateCount,
            ignored: extraction.ignoredURLCount
        )
    }

    private func configureQobuzAPI(from document: SettingsDocument) {
        let appID = document.qobuzAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = document.qobuzAppSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let authToken = document.qobuzAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appID.isEmpty,
              !appSecret.isEmpty,
              !authToken.isEmpty else {
            qobuzAPI = nil
            accountRegion = "??"
            previewState = .error(QobuzError.missingCredentials.localizedDescription)
            return
        }

        let api = QobuzAPI(
            appID: appID,
            appSecret: appSecret,
            authToken: authToken
        )
        qobuzAPI = api

        Task {
            do {
                accountRegion = try await api.region()
                if case .error = previewState, queuedLinks.isEmpty {
                    previewState = .idle
                }
            } catch {
                accountRegion = "??"
            }
        }
    }

    private func fetchPreview(for queueID: UUID) async {
        guard let index = queuedLinks.firstIndex(where: { $0.id == queueID }) else { return }
        let item = queuedLinks[index]

        guard let api = qobuzAPI else {
            let message = QobuzError.missingCredentials.localizedDescription
            cachePreview(.error(message), for: queueID, state: .metadataFailed(message))
            return
        }

        if queuedLinks[index].state.isMetadataMutable {
            queuedLinks[index].state = .loadingMetadata
        }
        previewState = .loading

        do {
            let loaded: PreviewState
            switch item.parsed {
            case .album(let id):
                let album = try await api.getAlbum(id: id)
                loaded = .loadedAlbum(AlbumPreviewInfo(from: album))
            case .track(let id):
                let track = try await api.getTrack(id: id)
                let album = try await api.getAlbum(id: track.album.id.value)
                loaded = .loadedTrack(TrackPreviewInfo(from: track, album: album))
            case .playlist:
                loaded = .loadedCollection(CollectionPreviewInfo(
                    kind: item.parsed,
                    title: "Qobuz Playlist",
                    subtitle: item.canonicalURL,
                    downloadURL: item.canonicalURL
                ))
            case .artist(let id):
                let artist = try await api.getArtist(id: id)
                loaded = .loadedArtist(ArtistPreviewInfo(from: artist, fallbackID: id))
            case .invalid:
                loaded = .error("Not a recognized Qobuz URL.")
            }

            cachePreview(loaded, for: queueID, state: .ready)
        } catch let error as QobuzError {
            switch error {
            case .regionBlocked:
                cachePreview(
                    .regionMismatch(yourRegion: accountRegion, blockedRegion: error.blockedCountry),
                    for: queueID,
                    state: .metadataFailed(error.localizedDescription)
                )
            default:
                cachePreview(.error(error.localizedDescription), for: queueID, state: .metadataFailed(error.localizedDescription))
            }
        } catch {
            cachePreview(.error(error.localizedDescription), for: queueID, state: .metadataFailed(error.localizedDescription))
        }
    }

    private func cachePreview(_ preview: PreviewState, for queueID: UUID, state: QueueItemState) {
        guard let index = queuedLinks.firstIndex(where: { $0.id == queueID }) else { return }

        queuedLinks[index].cachedPreview = preview
        applyPreviewSummary(preview, to: index)

        if queuedLinks[index].state.isMetadataMutable {
            queuedLinks[index].state = state
        }

        if selectedQueueID == queueID {
            previewState = preview
        }
    }

    private func applyPreviewSummary(_ preview: PreviewState, to index: Int) {
        switch preview {
        case .loadedAlbum(let info):
            queuedLinks[index].title = "\(info.artist) - \(info.title)"
            queuedLinks[index].subtitle = "\(info.trackCount) tracks"
            queuedLinks[index].coverURL = info.coverURL
        case .loadedTrack(let info):
            queuedLinks[index].title = "\(info.artist) - \(info.title)"
            queuedLinks[index].subtitle = "from \(info.albumTitle)"
            queuedLinks[index].coverURL = info.coverURL
        case .loadedArtist(let info):
            queuedLinks[index].title = info.name
            queuedLinks[index].subtitle = info.albumCount > 0 ? "\(info.albumCount) albums" : "Artist catalog"
            queuedLinks[index].coverURL = info.coverURL
        case .loadedCollection(let info):
            queuedLinks[index].title = info.title
            queuedLinks[index].subtitle = info.subtitle
        default:
            break
        }
    }

    private func startQueuedDownloads(ids: [UUID]) {
        let context: DownloadPreflightContext
        do {
            context = try preflightQueuedDownloads(ids: ids)
        } catch {
            presentPreflightFailure(error.localizedDescription)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isPreflighting = false
                self.preflightTask = nil
            }

            do {
                try Task.checkCancellation()
                try await verifyRemoteAvailability(for: context)
                try Task.checkCancellation()
            } catch is CancellationError {
                queueNotice = "Download preflight cancelled."
                return
            } catch {
                presentPreflightFailure(error.localizedDescription)
                return
            }

            for id in context.ids {
                setQueueState(id: id, state: .queued)
            }

            queueNotice = context.ids.count == 1
                ? "Preflight passed. Starting download."
                : "Preflight passed. Starting \(context.ids.count) downloads."

            activeDownloadTask = Task { [weak self] in
                guard let self else { return }
                for id in context.ids {
                    guard !Task.isCancelled else { break }
                    await self.runQueuedDownload(queueID: id)
                }

                self.finishBatch(ids: context.ids)
            }
        }

        preflightTask = task
        isPreflighting = true
        queueNotice = context.items.count == 1
            ? "Preparing download: checking Qobuz availability and selected quality..."
            : "Preparing downloads: checking \(context.items.count) Qobuz items and selected quality..."
    }

    private func runQueuedDownload(queueID: UUID) async {
        guard let index = queuedLinks.firstIndex(where: { $0.id == queueID }) else { return }
        let queueItem = queuedLinks[index]
        guard queueItem.parsed.downloadableURL != nil,
              queueItem.state == .queued || queueItem.state.canStart else {
            return
        }

        let id = UUID()
        let unit = progressUnit(for: queueItem.parsed)
        let startedAt = Date()
        let item = DownloadItem(
            id: id,
            queueID: queueID,
            url: queueItem.canonicalURL,
            title: queueItem.displayTitle,
            status: .queued,
            startedAt: startedAt,
            totalUnits: expectedUnitTotal(for: queueItem),
            progressUnit: unit
        )
        downloads.insert(item, at: 0)

        let runner = OrpheusRunner()
        runners[id] = runner
        activeDownloadID = id
        activeQueueID = queueID
        setQueueState(id: queueID, state: .downloading(id), downloadID: id)
        updateDownload(id: id, status: .downloading)

        let helperURL = runtime.helperURL
        let projectURL = runtime.runtimeProjectURL
        let outputURL = runtime.resolvedDownloadURL(from: settings?.downloadPath ?? "")

        do {
            let processStartedAt = Date()
            let stream = runner.runDownload(
                url: queueItem.canonicalURL,
                helperURL: helperURL,
                projectURL: projectURL,
                downloadURL: outputURL,
                environment: runnerEnvironment()
            )

            for try await event in stream {
                guard !Task.isCancelled else {
                    runner.cancel()
                    break
                }

                switch event {
                case .fileProgress(let progress):
                    if !shouldUseUnitProgress(id: id) {
                        updateDownload(
                            id: id,
                            progress: min(max(progress.percent / 100, 0), 1),
                            speed: progress.speed,
                            downloaded: progress.downloaded,
                            total: progress.total
                        )
                    } else {
                        updateDownload(
                            id: id,
                            speed: progress.speed,
                            downloaded: progress.downloaded,
                            total: progress.total
                        )
                    }
                case .trackProgress(let progress):
                    if !queueItem.parsed.isArtist {
                        updateDownload(
                            id: id,
                            progress: progressFraction(completed: progress.completed, total: progress.total),
                            completedUnits: progress.completed,
                            totalUnits: progress.total
                        )
                    }
                case .albumProgress(let progress):
                    if queueItem.parsed.isArtist {
                        updateDownload(
                            id: id,
                            progress: progressFraction(completed: progress.completed, total: progress.total),
                            completedUnits: progress.completed,
                            totalUnits: progress.total
                        )
                    }
                }
            }

            guard !Task.isCancelled else {
                markCancelled(downloadID: id, queueID: queueID)
                finishActive(downloadID: id)
                return
            }

            let total = downloads.first(where: { $0.id == id })?.totalUnits
            let resolvedOutputURL = outputResolver.resolveOutput(in: outputURL, startedAt: processStartedAt)
            updateDownload(
                id: id,
                status: .completed,
                progress: 1,
                completedUnits: total,
                resolvedOutputURL: resolvedOutputURL
            )
            setQueueState(id: queueID, state: .completed(id))
        } catch {
            if Task.isCancelled {
                markCancelled(downloadID: id, queueID: queueID)
            } else {
                updateDownload(id: id, status: .failed(error.localizedDescription))
                setQueueState(id: queueID, state: .failed(error.localizedDescription))
            }
        }

        finishActive(downloadID: id)
    }

    private func preflightQueuedDownloads(ids: [UUID]) throws -> DownloadPreflightContext {
        guard activeDownloadTask == nil else {
            throw DownloadPreflightError.failure("Cannot start download: another download is already running.")
        }

        guard !isPreflighting, preflightTask == nil else {
            throw DownloadPreflightError.failure("Cannot start download: preflight is already running.")
        }

        guard !ids.isEmpty else {
            throw DownloadPreflightError.failure("Cannot start download: no ready links selected.")
        }

        let items = ids.compactMap { id in
            queuedLinks.first { $0.id == id }
        }
        guard items.count == ids.count else {
            throw DownloadPreflightError.failure("Cannot start download: one or more queue items no longer exist.")
        }

        guard items.allSatisfy({ $0.state.canStart && $0.parsed.downloadableURL != nil }) else {
            throw DownloadPreflightError.failure("Cannot start download: one or more queue items are not ready.")
        }

        guard let document = settings else {
            throw DownloadPreflightError.failure("Cannot start download: settings are not loaded.")
        }

        let missingCredentials = [
            ("Qobuz app ID", document.qobuzAppID),
            ("Qobuz app secret", document.qobuzAppSecret),
            ("Qobuz auth token", document.qobuzAuthToken)
        ]
            .filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.0)

        guard missingCredentials.isEmpty else {
            throw DownloadPreflightError.failure(
                "Cannot start download: missing \(missingCredentials.joined(separator: ", ")). Open Settings."
            )
        }

        let quality = selectedQuality.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validDownloadQualities.contains(quality) else {
            throw DownloadPreflightError.failure("Cannot start download: choose a valid download quality in Settings.")
        }
        guard QobuzDownloadQuality.formatID(for: quality) != nil else {
            throw DownloadPreflightError.failure("Cannot start download: unsupported Qobuz quality \(quality).")
        }

        let api = qobuzAPI ?? QobuzAPI(
            appID: document.qobuzAppID,
            appSecret: document.qobuzAppSecret,
            authToken: document.qobuzAuthToken
        )

        try verifyRuntimeFolder()
        do {
            try runtime.verifyHelperExists()
        } catch {
            throw DownloadPreflightError.failure("Cannot start download: \(error.localizedDescription)")
        }
        try verifyFFmpegIfNeeded(for: document)
        try verifyDownloadFolder(for: document)

        settings?.downloadQuality = quality
        do {
            try persistCurrentSettings(reload: false)
        } catch {
            throw DownloadPreflightError.failure(
                "Cannot start download: could not save selected quality. \(error.localizedDescription)"
            )
        }
        selectedQuality = quality

        return DownloadPreflightContext(ids: ids, items: items, quality: quality, api: api)
    }

    private func verifyRemoteAvailability(for context: DownloadPreflightContext) async throws {
        for item in context.items {
            try Task.checkCancellation()
            do {
                try await verifyRemoteAvailability(for: item, quality: context.quality, api: context.api)
            } catch {
                if error is CancellationError { throw error }
                let message = "Cannot start download: \(item.displayTitle) failed preflight. \(error.localizedDescription)"
                markPreflightFailed(queueID: item.id, message: message)
                throw DownloadPreflightError.failure(message)
            }
        }
    }

    private func verifyRemoteAvailability(
        for item: QueuedLink,
        quality: String,
        api: QobuzServicing
    ) async throws {
        switch item.parsed {
        case .album(let id):
            let album = try await api.getAlbum(id: id)
            guard album.isBrowseAvailable else {
                throw DownloadPreflightError.failure(album.browseUnavailableReason ?? "Album is not available.")
            }
            let tracks = album.tracks?.items ?? []
            guard let firstTrack = tracks.first else {
                throw DownloadPreflightError.failure("Album has no tracks available to download.")
            }
            try await verifyTrackQuality(trackID: firstTrack.id.value, quality: quality, api: api)
            cachePreflightPreview(.loadedAlbum(AlbumPreviewInfo(from: album)), for: item.id)

        case .track(let id):
            let track = try await api.getTrack(id: id)
            guard track.isBrowseAvailable else {
                throw DownloadPreflightError.failure("Track is not available or downloadable for this account region.")
            }
            try await verifyTrackQuality(trackID: track.id.value, quality: quality, api: api)

        case .artist(let id):
            let artist = try await api.getArtist(id: id)
            let albums = (artist.albums?.items ?? []).filter(\.isBrowseAvailable)
            guard let firstAlbumRef = albums.first else {
                throw DownloadPreflightError.failure("Artist has no available albums for this account region.")
            }
            let firstAlbum = try await api.getAlbum(id: firstAlbumRef.id.value)
            guard let firstTrack = firstAlbum.tracks?.items.first else {
                throw DownloadPreflightError.failure("Artist catalog has no downloadable tracks.")
            }
            try await verifyTrackQuality(trackID: firstTrack.id.value, quality: quality, api: api)
            cachePreflightPreview(.loadedArtist(ArtistPreviewInfo(from: artist, fallbackID: id)), for: item.id)

        case .playlist(let id):
            let playlist = try await api.getPlaylist(id: id)
            guard let firstTrack = playlist.tracks?.items.first else {
                throw DownloadPreflightError.failure("Playlist has no tracks available to download.")
            }
            try await verifyTrackQuality(trackID: firstTrack.id.value, quality: quality, api: api)

        case .invalid:
            throw DownloadPreflightError.failure("Not a recognized Qobuz URL.")
        }
    }

    private func verifyTrackQuality(trackID: String, quality: String, api: QobuzServicing) async throws {
        let response = try await api.getFileURL(trackID: trackID, quality: quality)
        guard response.hasPlayableURL else {
            throw DownloadPreflightError.failure("Selected quality is not downloadable for this item.")
        }
    }

    private func cachePreflightPreview(_ preview: PreviewState, for queueID: UUID) {
        guard let index = queuedLinks.firstIndex(where: { $0.id == queueID }) else { return }
        queuedLinks[index].cachedPreview = preview
        applyPreviewSummary(preview, to: index)
        if selectedQueueID == queueID {
            previewState = preview
        }
    }

    private func markPreflightFailed(queueID: UUID, message: String) {
        setQueueState(id: queueID, state: .metadataFailed(message))
        if selectedQueueID == queueID {
            previewState = .error(message)
        }
    }

    private func verifyRuntimeFolder() throws {
        var isDirectory = ObjCBool(false)
        guard runtime.fileManager.fileExists(atPath: runtime.runtimeProjectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DownloadPreflightError.failure(
                "Cannot start download: OrpheusDL runtime folder is missing. Restart the app to recreate it."
            )
        }
    }

    private func verifyFFmpegIfNeeded(for document: SettingsDocument) throws {
        guard document.codecConversionsEnabled else { return }
        guard let ffmpegURL = runtime.ffmpegURL else {
            throw DownloadPreflightError.failure(
                "Cannot start download: codec conversion is enabled, but bundled ffmpeg is missing."
            )
        }
        guard runtime.fileManager.isExecutableFile(atPath: ffmpegURL.path) else {
            throw DownloadPreflightError.failure(
                "Cannot start download: bundled ffmpeg is not executable."
            )
        }
    }

    private func verifyDownloadFolder(for document: SettingsDocument) throws {
        let outputURL = runtime.resolvedDownloadURL(from: document.downloadPath)

        do {
            try runtime.fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

            var isDirectory = ObjCBool(false)
            guard runtime.fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DownloadPreflightError.failure("Cannot start download: download path is not a folder.")
            }

            let probe = outputURL.appendingPathComponent(".orpheus-ui-write-test-\(UUID().uuidString)")
            try Data().write(to: probe, options: .atomic)
            try? runtime.fileManager.removeItem(at: probe)
        } catch let error as DownloadPreflightError {
            throw error
        } catch {
            throw DownloadPreflightError.failure(
                "Cannot start download: cannot write to download folder. \(error.localizedDescription)"
            )
        }
    }

    private func presentPreflightFailure(_ message: String) {
        queueNotice = message
        if selectedQueueID == nil {
            previewState = .error(message)
        }
    }

    private func cancelPreflight() {
        guard isPreflighting || preflightTask != nil else { return }
        preflightTask?.cancel()
        isPreflighting = false
        preflightTask = nil
        queueNotice = "Download preflight cancelled."
    }

    private func cancelActiveDownload() {
        activeDownloadTask?.cancel()
        if let activeDownloadID {
            runners[activeDownloadID]?.cancel()
        }

        if let activeDownloadID, let activeQueueID {
            markCancelled(downloadID: activeDownloadID, queueID: activeQueueID)
        }
    }

    private func markCancelled(downloadID: UUID, queueID: UUID) {
        guard let download = downloads.first(where: { $0.id == downloadID }),
              download.status.isActive else {
            return
        }
        updateDownload(id: downloadID, status: .cancelled)
        if let queue = queuedLinks.first(where: { $0.id == queueID }),
           queue.state.isActive {
            setQueueState(id: queueID, state: .cancelled)
        }
    }

    private func finishActive(downloadID: UUID) {
        runners[downloadID] = nil
        if activeDownloadID == downloadID {
            activeDownloadID = nil
            activeQueueID = nil
        }
    }

    private func finishBatch(ids: [UUID]) {
        for id in ids {
            if let index = queuedLinks.firstIndex(where: { $0.id == id }),
               queuedLinks[index].state == .queued {
                queuedLinks[index].state = .ready
            }
        }
        activeDownloadTask = nil
    }

    private func setQueueState(id: UUID, state: QueueItemState, downloadID: UUID? = nil) {
        guard let index = queuedLinks.firstIndex(where: { $0.id == id }) else { return }
        queuedLinks[index].state = state
        if let downloadID {
            queuedLinks[index].downloadID = downloadID
        }
    }

    private func saveSettings(reload: Bool) {
        do {
            try persistCurrentSettings(reload: reload)
        } catch {
            previewState = .error(error.localizedDescription)
        }
    }

    private func persistCurrentSettings(reload: Bool) throws {
        guard let settings else { return }
        try SettingsStore.save(settings, to: runtime.settingsURL)
        if reload {
            loadSettings()
        }
    }

    private func expectedUnitTotal(for item: QueuedLink) -> Int? {
        switch item.cachedPreview {
        case .loadedAlbum(let info):
            return info.trackCount > 0 ? info.trackCount : nil
        case .loadedTrack:
            return 1
        case .loadedArtist(let info):
            return info.albumCount > 0 ? info.albumCount : nil
        default:
            return nil
        }
    }

    private func progressUnit(for parsed: QobuzURLParseResult) -> DownloadProgressUnit {
        parsed.isArtist ? .albums : .tracks
    }

    private func shouldUseUnitProgress(id: UUID) -> Bool {
        guard let item = downloads.first(where: { $0.id == id }) else { return false }
        return (item.totalUnits ?? 0) > 1
    }

    private func progressFraction(completed: Int, total: Int?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    private func runnerEnvironment() -> [String: String] {
        guard let ffmpegURL = runtime.ffmpegURL else { return [:] }
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ["PATH": "\(ffmpegURL.deletingLastPathComponent().path):\(existingPath)"]
    }

    private func updateDownload(
        id: UUID,
        status: DownloadStatus? = nil,
        progress: Double? = nil,
        speed: String? = nil,
        downloaded: String? = nil,
        total: String? = nil,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        resolvedOutputURL: URL? = nil
    ) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        if let status { downloads[index].status = status }
        if let progress { downloads[index].progress = progress }
        if let speed { downloads[index].speed = speed }
        if let downloaded { downloads[index].downloaded = downloaded }
        if let total { downloads[index].total = total }
        if let completedUnits { downloads[index].completedUnits = completedUnits }
        if let totalUnits { downloads[index].totalUnits = totalUnits }
        if let resolvedOutputURL { downloads[index].resolvedOutputURL = resolvedOutputURL }
    }

    private func linkNotice(added: Int, invalid: Int, duplicates: Int, ignored: Int) -> String? {
        var parts: [String] = []
        if invalid > 0 {
            parts.append("\(invalid) invalid Qobuz \(invalid == 1 ? "link" : "links")")
        }
        if duplicates > 0 {
            parts.append("\(duplicates) duplicate \(duplicates == 1 ? "skipped" : "skipped")")
        }
        if added == 0 && invalid == 0 && duplicates == 0 && ignored > 0 {
            parts.append("No Qobuz links found")
        }
        if added == 0 && invalid == 0 && duplicates == 0 && ignored == 0 {
            parts.append("No Qobuz links found")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ") + "."
    }
}

enum PreviewState: Equatable {
    case idle
    case loading
    case loadedAlbum(AlbumPreviewInfo)
    case loadedTrack(TrackPreviewInfo)
    case loadedArtist(ArtistPreviewInfo)
    case loadedCollection(CollectionPreviewInfo)
    case regionMismatch(yourRegion: String, blockedRegion: String?)
    case error(String)
}

enum RegionDisplay {
    static func display(_ region: String) -> String {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = trimmed.uppercased()
        guard let flag = flag(for: code) else { return trimmed }
        return "\(flag) \(code)"
    }

    private static func flag(for code: String) -> String? {
        guard code.count == 2 else { return nil }

        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard (65...90).contains(scalar.value),
                  let regionalIndicator = UnicodeScalar(127397 + scalar.value) else {
                return nil
            }
            scalars.append(regionalIndicator)
        }
        return String(scalars)
    }
}

// MARK: - Browse State

enum BrowseRoute: Equatable {
    case idle
    case loading
    case results
    case artistDetail(artist: QobuzSearchArtist, albums: [QobuzAlbumResponse])
    case albumDetail(album: AlbumPreviewInfo, tracks: [QobuzTrackRef])
    case error(String)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

enum BrowseCategory: String, CaseIterable, Identifiable, Hashable {
    case albums, artists, tracks
    var id: Self { self }

    var label: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .tracks: return "Tracks"
        }
    }

    var shortLabel: String {
        switch self {
        case .albums: return "Alb"
        case .artists: return "Art"
        case .tracks: return "Trk"
        }
    }

    var iconName: String {
        switch self {
        case .albums: return "square.stack"
        case .artists: return "person.crop.circle"
        case .tracks: return "music.note"
        }
    }

    var searchType: SearchType {
        switch self {
        case .albums:
            return .album
        case .artists:
            return .artist
        case .tracks:
            return .track
        }
    }
}

enum BrowseLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct BrowseCategoryResult: Equatable {
    var albums: [QobuzAlbumResponse] = []
    var artists: [QobuzSearchArtist] = []
    var tracks: [QobuzTrackResponse] = []
    var unavailableCount: Int = 0
    var state: BrowseLoadState = .idle

    var count: Int {
        max(albums.count, artists.count, tracks.count)
    }

    mutating func load() {
        state = .loaded
    }

    mutating func fail(_ message: String) {
        state = .failed(message)
    }
}

struct BrowseResults: Equatable {
    var albums = BrowseCategoryResult()
    var artists = BrowseCategoryResult()
    var tracks = BrowseCategoryResult()

    static var empty: BrowseResults {
        BrowseResults()
    }

    static func loadingAll() -> BrowseResults {
        BrowseResults(
            albums: BrowseCategoryResult(state: .loading),
            artists: BrowseCategoryResult(state: .loading),
            tracks: BrowseCategoryResult(state: .loading)
        )
    }

    subscript(category: BrowseCategory) -> BrowseCategoryResult {
        get {
            switch category {
            case .albums: return albums
            case .artists: return artists
            case .tracks: return tracks
            }
        }
        set {
            switch category {
            case .albums: albums = newValue
            case .artists: artists = newValue
            case .tracks: tracks = newValue
            }
        }
    }

    func count(for category: BrowseCategory) -> Int {
        self[category].count
    }
}

private struct BrowseAlbumResolution {
    let albums: [QobuzAlbumResponse]
    let unavailableCount: Int
}

struct QueuedLink: Identifiable, Equatable {
    let id: UUID
    let originalURL: String
    let canonicalURL: String
    let parsed: QobuzURLParseResult
    var title: String?
    var subtitle: String?
    var coverURL: String?
    var state: QueueItemState
    var cachedPreview: PreviewState?
    var downloadID: UUID?

    init(
        id: UUID = UUID(),
        originalURL: String,
        canonicalURL: String,
        parsed: QobuzURLParseResult,
        title: String?,
        subtitle: String?,
        coverURL: String?,
        state: QueueItemState,
        cachedPreview: PreviewState?,
        downloadID: UUID?
    ) {
        self.id = id
        self.originalURL = originalURL
        self.canonicalURL = canonicalURL
        self.parsed = parsed
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.state = state
        self.cachedPreview = cachedPreview
        self.downloadID = downloadID
    }

    static func invalid(url: String) -> QueuedLink {
        QueuedLink(
            originalURL: url,
            canonicalURL: url,
            parsed: .invalid,
            title: "Invalid Qobuz URL",
            subtitle: url,
            coverURL: nil,
            state: .invalid("Not a recognized Qobuz URL."),
            cachedPreview: .error("Not a recognized Qobuz URL."),
            downloadID: nil
        )
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return parsed == .invalid ? "Invalid Qobuz URL" : parsed.contentTypeName
    }

    var displaySubtitle: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return canonicalURL
    }
}

enum QueueItemState: Equatable {
    case ready
    case loadingMetadata
    case metadataFailed(String)
    case invalid(String)
    case queued
    case downloading(UUID)
    case completed(UUID)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading:
            return true
        default:
            return false
        }
    }

    var isMetadataMutable: Bool {
        switch self {
        case .ready, .loadingMetadata, .metadataFailed:
            return true
        default:
            return false
        }
    }

    var canStart: Bool {
        switch self {
        case .ready, .metadataFailed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .ready:
            return "Ready"
        case .loadingMetadata:
            return "Loading"
        case .metadataFailed:
            return "Preview failed"
        case .invalid:
            return "Invalid"
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    let queueID: UUID?
    let url: String
    let title: String
    var status: DownloadStatus
    var startedAt: Date = Date()
    var progress: Double = 0
    var speed: String?
    var downloaded: String?
    var total: String?
    var completedUnits: Int = 0
    var totalUnits: Int?
    var progressUnit: DownloadProgressUnit
    var resolvedOutputURL: URL?

    var unitProgressLabel: String? {
        guard let totalUnits, totalUnits > 1 else { return nil }
        return "\(min(completedUnits, totalUnits))/\(totalUnits) \(progressUnit.pluralName)"
    }

    var speedBadgeLabel: String? {
        guard case .downloading = status,
              let speed = speed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speed.isEmpty else {
            return nil
        }
        return speed
    }
}

private struct DownloadPreflightContext {
    let ids: [UUID]
    let items: [QueuedLink]
    let quality: String
    let api: any QobuzServicing
}

enum DownloadProgressUnit: Equatable {
    case tracks
    case albums

    var pluralName: String {
        switch self {
        case .tracks:
            return "tracks"
        case .albums:
            return "albums"
        }
    }
}

enum DownloadStatus: Equatable {
    case queued
    case downloading
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var isClearable: Bool {
        !isActive
    }
}

enum DownloadPreflightError: LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private extension QobuzURLParseResult {
    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}

protocol FinderRevealing: AnyObject {
    func reveal(urls: [URL])
}

final class WorkspaceFinderRevealer: FinderRevealing {
    func reveal(urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

struct DownloadOutputResolver {
    let fileManager: FileManager

    func resolveOutput(in root: URL, startedAt: Date) -> URL? {
        let cutoff = startedAt.addingTimeInterval(-2)
        guard let candidates = try? candidates(in: root, cutoff: cutoff), !candidates.isEmpty else {
            return nil
        }

        if let direct = candidates
            .filter({ $0.isDirectChild })
            .max(by: { $0.date < $1.date }) {
            return direct.url
        }

        return candidates.max(by: { $0.date < $1.date })?.url
    }

    private func candidates(in root: URL, cutoff: Date) throws -> [OutputCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isHiddenKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let standardizedRoot = root.standardizedFileURL
        var output: [OutputCandidate] = []

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isHiddenKey
            ])
            if values.isHidden == true { continue }

            let date = [values.contentModificationDate, values.creationDate]
                .compactMap { $0 }
                .max()
            guard let date, date >= cutoff else { continue }

            output.append(OutputCandidate(
                url: url,
                date: date,
                isDirectChild: url.deletingLastPathComponent().standardizedFileURL.path == standardizedRoot.path
            ))
        }

        return output
    }

    private struct OutputCandidate {
        let url: URL
        let date: Date
        let isDirectChild: Bool
    }
}
