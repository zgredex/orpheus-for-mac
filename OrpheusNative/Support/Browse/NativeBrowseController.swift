import Combine
import Foundation
import NativeQobuzCore

/// Owns catalog search, pagination, browse navigation, and account-aware
/// availability presentation. App-level navigation coordinates it with Library.
@MainActor
final class NativeBrowseController: ObservableObject {
    @Published private(set) var query = ""
    @Published var category: NativeBrowseCategory = .albums
    @Published private(set) var results = NativeBrowseResults()
    @Published private(set) var loadingCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var loadingMoreCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var errors: [NativeBrowseCategory: String] = [:]
    @Published private(set) var loadMoreErrors: [NativeBrowseCategory: String] = [:]
    @Published private(set) var isOpen = false
    @Published private(set) var path: [BrowsePage] = []

    private var client: (any NativeQobuzServicing)?
    private var availabilityPolicy = NativeBrowseAvailabilityPolicy(accountRegion: nil)
    private var searchTasks: [Task<Void, Never>] = []
    private var searchRequestID: UUID?
    private var pageTask: Task<Void, Never>?

    var isLoading: Bool {
        !loadingCategories.isEmpty || !loadingMoreCategories.isEmpty
    }

    var statusText: String {
        if !loadingCategories.isEmpty { return "Searching all categories" }
        let loaded = results.totalCount
        if !loadingMoreCategories.isEmpty { return "\(loaded) loaded · Loading more" }
        if results.hasMoreResults { return "\(loaded) loaded" }
        return loaded == 1 ? "1 result" : "\(loaded) results"
    }

    var albums: [QobuzAlbumSummary] { results.albums }
    var artists: [QobuzArtist] { results.artists }
    var playlists: [QobuzPlaylist] { results.playlists }
    var tracks: [QobuzTrack] { results.tracks }

    func configure(client: (any NativeQobuzServicing)?, accountRegion: String?) {
        self.client = client
        availabilityPolicy.accountRegion = accountRegion
    }

    func updateAccountRegion(_ accountRegion: String?) {
        availabilityPolicy.accountRegion = accountRegion
    }

    func search(_ query: String) throws {
        let client = try configuredClient(operation: "searching")
        cancelSearchTasks()
        let requestID = UUID()
        searchRequestID = requestID
        self.query = query
        results = NativeBrowseResults()
        errors = [:]
        loadMoreErrors = [:]
        pageTask?.cancel()
        path = []
        loadingCategories = Set(NativeBrowseCategory.allCases)
        loadingMoreCategories = []
        category = .albums
        isOpen = true
        qobuzLog.notice(
            "browse.search",
            "Catalog search started",
            metadata: [
                "searchID": requestID.uuidString,
                "query": query,
                "categoryCount": String(NativeBrowseCategory.allCases.count)
            ]
        )

        for category in NativeBrowseCategory.allCases {
            searchTasks.append(Task { [weak self] in
                do {
                    let page = try await QobuzLogScope.withValue([
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
                    guard let self, searchRequestID == requestID, !Task.isCancelled else { return }
                    qobuzLog.info(
                        "browse.search",
                        "Search category loaded",
                        metadata: [
                            "searchID": requestID.uuidString,
                            "category": category.rawValue,
                            "loadedCount": String(Self.count(in: page, category: category)),
                            "totalCount": page.total.map(String.init) ?? "unknown"
                        ]
                    )
                    apply(page, category: category)
                } catch {
                    guard let self, searchRequestID == requestID, !Task.isCancelled else { return }
                    qobuzLog.error(
                        "browse.search",
                        "Search category failed",
                        metadata: [
                            "searchID": requestID.uuidString,
                            "category": category.rawValue,
                            "query": query
                        ],
                        error: error
                    )
                    loadingCategories.remove(category)
                    errors[category] = error.localizedDescription
                }
            })
        }
    }

    func close() {
        cancelSearchTasks()
        loadingCategories = []
        loadingMoreCategories = []
        pageTask?.cancel()
        pageTask = nil
        path = []
        isOpen = false
    }

    func open(_ destination: BrowseDestination) throws {
        let client = try configuredClient(operation: "browsing")
        pageTask?.cancel()
        let page = BrowsePage(id: UUID(), destination: destination, content: .loading)
        let metadata = Self.metadata(for: destination)
            .merging(["browsePageID": page.id.uuidString]) { _, new in new }
        path.append(page)
        isOpen = true
        qobuzLog.info("browse.page", "Browse page loading started", metadata: metadata)
        let policy = availabilityPolicy
        pageTask = Task { [weak self] in
            do {
                let content: BrowsePageContent
                let availability: NativeBrowseAvailability
                (content, availability) = try await QobuzLogScope.withValue(metadata) {
                    switch destination {
                    case .album(let id):
                        let value = try await client.album(id: id)
                        return (.album(value), policy.availability(for: value))
                    case .artist(let id):
                        let value = try await client.artist(id: id)
                        return (.artist(value), policy.availability(for: value))
                    case .track(let id):
                        let value = try await client.track(id: id)
                        return (.track(value), policy.availability(for: value))
                    case .playlist(let id):
                        let value = try await client.playlist(id: id)
                        return (.playlist(value), policy.availability(for: value))
                    case .label(let id):
                        let value = try await client.label(id: id)
                        return (.label(value), policy.availability(for: value))
                    }
                }
                guard let self, !Task.isCancelled else { return }
                qobuzLog.info("browse.page", "Browse page loaded", metadata: metadata)
                updatePage(page.id, content: content, availability: availability)
            } catch {
                guard let self, !Task.isCancelled else { return }
                qobuzLog.error("browse.page", "Browse page failed to load", metadata: metadata, error: error)
                let message = policy.errorMessage(error)
                updatePage(
                    page.id,
                    content: .error(message),
                    availability: policy.failureAvailability(for: error, message: message)
                )
            }
        }
    }

    func open(_ request: QobuzRequest) throws {
        resetSearch()
        switch request {
        case .album(let id): try open(BrowseDestination.album(id))
        case .artist(let id): try open(BrowseDestination.artist(id))
        case .track(let id): try open(BrowseDestination.track(id))
        case .playlist(let id): try open(BrowseDestination.playlist(id))
        case .label(let id): try open(BrowseDestination.label(id))
        }
    }

    func back() {
        pageTask?.cancel()
        pageTask = nil
        _ = path.popLast()
        if path.isEmpty, query.isEmpty { close() }
    }

    func retryPage() throws {
        guard let page = path.popLast() else { return }
        try open(page.destination)
    }

    func retrySearch() throws {
        guard !query.isEmpty else { return }
        let selectedCategory = category
        try search(query)
        category = selectedCategory
    }

    func count(for category: NativeBrowseCategory) -> Int {
        results.count(for: category)
    }

    func countLabel(for category: NativeBrowseCategory) -> String {
        let loaded = results.count(for: category)
        return "\(loaded)\(results.nextOffset(for: category) == nil ? "" : "+")"
    }

    func canLoadMore(for category: NativeBrowseCategory) -> Bool {
        results.nextOffset(for: category) != nil
    }

    func isLoadingMore(for category: NativeBrowseCategory) -> Bool {
        loadingMoreCategories.contains(category)
    }

    func loadMore(for category: NativeBrowseCategory) {
        guard let client,
              let requestID = searchRequestID,
              let offset = results.nextOffset(for: category),
              !loadingMoreCategories.contains(category),
              !query.isEmpty else { return }

        let query = query
        loadingMoreCategories.insert(category)
        loadMoreErrors.removeValue(forKey: category)
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
        searchTasks.append(Task { [weak self] in
            do {
                let page = try await QobuzLogScope.withValue([
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
                      searchRequestID == requestID,
                      self.query == query,
                      !Task.isCancelled else { return }
                results.append(page, for: category)
                loadingMoreCategories.remove(category)
                qobuzLog.info(
                    "browse.pagination",
                    "Next search result page loaded",
                    metadata: [
                        "searchID": requestID.uuidString,
                        "category": category.rawValue,
                        "offset": String(offset),
                        "nextOffset": page.nextOffset.map(String.init) ?? "none",
                        "loadedTotal": String(results.count(for: category))
                    ]
                )
            } catch {
                guard let self,
                      searchRequestID == requestID,
                      self.query == query,
                      !Task.isCancelled else { return }
                qobuzLog.error(
                    "browse.pagination",
                    "Next search result page failed",
                    metadata: [
                        "searchID": requestID.uuidString,
                        "category": category.rawValue,
                        "offset": String(offset)
                    ],
                    error: error
                )
                loadingMoreCategories.remove(category)
                loadMoreErrors[category] = error.localizedDescription
            }
        })
    }

    func availability(for album: QobuzAlbum) -> NativeBrowseAvailability {
        availabilityPolicy.availability(for: album)
    }

    func availability(for track: QobuzTrack) -> NativeBrowseAvailability {
        availabilityPolicy.availability(for: track)
    }

    func availability(for playlist: QobuzPlaylist) -> NativeBrowseAvailability {
        availabilityPolicy.availability(for: playlist)
    }

    func availability(for artist: QobuzArtistCatalog) -> NativeBrowseAvailability {
        availabilityPolicy.availability(for: artist)
    }

    func availability(for label: QobuzLabelCatalog) -> NativeBrowseAvailability {
        availabilityPolicy.availability(for: label)
    }

    func unavailabilityMessage(for track: QobuzTrack) -> String? {
        availabilityPolicy.unavailabilityMessage(for: track)
    }

    func errorMessage(_ error: Error) -> String {
        availabilityPolicy.errorMessage(error)
    }

    private func configuredClient(operation: String) throws -> any NativeQobuzServicing {
        guard let client else {
            qobuzLog.warning(
                "browse.configuration",
                "Browse operation blocked because credentials are not configured",
                metadata: ["operation": operation]
            )
            throw NativeQobuzError.unavailable(
                "Configure Qobuz credentials before \(operation)."
            )
        }
        return client
    }

    private func apply(_ page: QobuzSearchResults, category: NativeBrowseCategory) {
        results.replace(page, for: category)
        loadingCategories.remove(category)
        if loadingCategories.isEmpty, self.category == .albums, albums.isEmpty {
            self.category = results.firstNonemptyCategory ?? .albums
        }
    }

    private func updatePage(
        _ id: UUID,
        content: BrowsePageContent,
        availability: NativeBrowseAvailability
    ) {
        guard let index = path.firstIndex(where: { $0.id == id }) else { return }
        path[index].content = content
        path[index].availability = availability
    }

    private func resetSearch() {
        cancelSearchTasks()
        pageTask?.cancel()
        pageTask = nil
        searchRequestID = nil
        query = ""
        results = NativeBrowseResults()
        errors = [:]
        loadMoreErrors = [:]
        loadingCategories = []
        loadingMoreCategories = []
        path = []
    }

    private func cancelSearchTasks() {
        searchTasks.forEach { $0.cancel() }
        searchTasks.removeAll()
    }

    private static func metadata(for destination: BrowseDestination) -> [String: String] {
        switch destination {
        case .album(let id): ["browseKind": "album", "qobuzID": id.rawValue]
        case .artist(let id): ["browseKind": "artist", "qobuzID": id.rawValue]
        case .track(let id): ["browseKind": "track", "qobuzID": id.rawValue]
        case .playlist(let id): ["browseKind": "playlist", "qobuzID": id.rawValue]
        case .label(let id): ["browseKind": "label", "qobuzID": id.rawValue]
        }
    }

    private static func count(
        in page: QobuzSearchResults,
        category: NativeBrowseCategory
    ) -> Int {
        switch category {
        case .albums: page.albums.count
        case .artists: page.artists.count
        case .playlists: page.playlists.count
        case .tracks: page.tracks.count
        }
    }
}
