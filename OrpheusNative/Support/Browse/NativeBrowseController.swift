import Combine
import Foundation
import NativeQobuzCore

/// Owns detail-page navigation and delegates search state to its dedicated
/// component. Collection detail pages load incrementally; queue resolution
/// remains exhaustive in the core catalog service.
@MainActor
final class NativeBrowseController: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var path: [BrowsePage] = []

    private let searchController: NativeCatalogSearchController
    private var client: (any NativeQobuzServicing)?
    private var availabilityPolicy = NativeCatalogAvailabilityPolicy(accountRegion: nil)
    private var searchObservation: AnyCancellable?
    private var pageTask: Task<Void, Never>?

    init(searchController: NativeCatalogSearchController? = nil) {
        let resolvedSearch = searchController ?? NativeCatalogSearchController()
        self.searchController = resolvedSearch
        searchObservation = resolvedSearch.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var query: String { searchController.query }
    var category: NativeBrowseCategory {
        get { searchController.category }
        set { searchController.category = newValue }
    }
    var results: NativeBrowseResults { searchController.results }
    var loadingCategories: Set<NativeBrowseCategory> { searchController.loadingCategories }
    var errors: [NativeBrowseCategory: String] { searchController.errors }
    var loadMoreErrors: [NativeBrowseCategory: String] { searchController.loadMoreErrors }
    var isLoading: Bool { searchController.isLoading }
    var statusText: String { searchController.statusText }
    var albums: [QobuzAlbumSummary] { results.albums }
    var artists: [QobuzArtist] { results.artists }
    var playlists: [QobuzPlaylist] { results.playlists }
    var tracks: [QobuzTrack] { results.tracks }

    func configure(client: (any NativeQobuzServicing)?, accountRegion: String?) {
        self.client = client
        searchController.configure(client: client)
        availabilityPolicy.accountRegion = accountRegion
    }

    func updateAccountRegion(_ accountRegion: String?) {
        availabilityPolicy.accountRegion = accountRegion
    }

    func search(_ value: String) throws {
        pageTask?.cancel()
        path = []
        try searchController.search(value)
        isOpen = true
    }

    func close() {
        searchController.reset()
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
        let loader = NativeBrowsePageLoader(client: client)
        let policy = availabilityPolicy
        pageTask = Task { [weak self] in
            do {
                let loaded = try await QobuzLogScope.withValue(metadata) {
                    try await loader.initial(destination)
                }
                guard let self, !Task.isCancelled else { return }
                let complete = loaded.pagination?.nextOffset == nil
                updatePage(
                    page.id,
                    content: loaded.content,
                    availability: policy.availability(for: loaded.content, collectionComplete: complete),
                    pagination: loaded.pagination
                )
                qobuzLog.info("browse.page", "Browse page loaded", metadata: metadata)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let message = policy.errorMessage(error)
                updatePage(
                    page.id,
                    content: .error(message),
                    availability: policy.failureAvailability(for: error, message: message),
                    pagination: nil
                )
                qobuzLog.error("browse.page", "Browse page failed to load", metadata: metadata, error: error)
            }
        }
    }

    func open(_ request: QobuzRequest) throws {
        searchController.reset()
        switch request {
        case .album(let id): try open(BrowseDestination.album(id))
        case .artist(let id): try open(BrowseDestination.artist(id))
        case .track(let id): try open(BrowseDestination.track(id))
        case .playlist(let id): try open(BrowseDestination.playlist(id))
        case .label(let id): try open(BrowseDestination.label(id))
        }
    }

    func loadMoreCurrentPage() {
        guard let client,
              let index = path.indices.last,
              let offset = path[index].pagination?.nextOffset,
              path[index].pagination?.isLoading != true else { return }
        let page = path[index]
        path[index].pagination?.isLoading = true
        path[index].pagination?.errorMessage = nil
        let loader = NativeBrowsePageLoader(client: client)
        let policy = availabilityPolicy
        let metadata = Self.metadata(for: page.destination).merging([
            "browsePageID": page.id.uuidString,
            "offset": String(offset),
            "limit": String(NativeBrowsePageLoader.pageSize)
        ]) { _, new in new }
        qobuzLog.info("browse.collection.pagination", "Loading next collection page", metadata: metadata)
        pageTask = Task { [weak self] in
            do {
                let next = try await QobuzLogScope.withValue(metadata) {
                    try await loader.next(page.destination, offset: offset)
                }
                let merged = try NativeBrowsePageReducer.append(
                    next,
                    to: page.content,
                    pageSize: NativeBrowsePageLoader.pageSize
                )
                guard let self,
                      let current = path.firstIndex(where: { $0.id == page.id }),
                      !Task.isCancelled else { return }
                path[current].content = merged.content
                path[current].pagination = merged.pagination
                path[current].availability = policy.availability(
                    for: merged.content,
                    collectionComplete: merged.pagination?.nextOffset == nil
                )
                qobuzLog.info(
                    "browse.collection.pagination",
                    "Next collection page loaded",
                    metadata: metadata.merging([
                        "nextOffset": merged.pagination?.nextOffset.map(String.init) ?? "none",
                        "loadedCount": String(Self.collectionCount(merged.content))
                    ]) { _, new in new }
                )
            } catch {
                guard let self,
                      let current = path.firstIndex(where: { $0.id == page.id }),
                      !Task.isCancelled else { return }
                path[current].pagination?.isLoading = false
                path[current].pagination?.errorMessage = error.localizedDescription
                qobuzLog.error(
                    "browse.collection.pagination",
                    "Next collection page failed",
                    metadata: metadata,
                    error: error
                )
            }
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

    func retrySearch() throws { try searchController.retry() }
    func count(for category: NativeBrowseCategory) -> Int { results.count(for: category) }
    func countLabel(for category: NativeBrowseCategory) -> String { searchController.countLabel(for: category) }
    func canLoadMore(for category: NativeBrowseCategory) -> Bool { searchController.canLoadMore(for: category) }
    func isLoadingMore(for category: NativeBrowseCategory) -> Bool {
        searchController.loadingMoreCategories.contains(category)
    }
    func loadMore(for category: NativeBrowseCategory) { searchController.loadMore(for: category) }
    func availability(for album: QobuzAlbum) -> NativeBrowseAvailability { availabilityPolicy.availability(for: album) }
    func availability(for track: QobuzTrack) -> NativeBrowseAvailability { availabilityPolicy.availability(for: track) }
    func availability(for playlist: QobuzPlaylist) -> NativeBrowseAvailability { availabilityPolicy.availability(for: playlist) }
    func availability(for artist: QobuzArtistCatalog) -> NativeBrowseAvailability { availabilityPolicy.availability(for: artist) }
    func availability(for label: QobuzLabelCatalog) -> NativeBrowseAvailability { availabilityPolicy.availability(for: label) }
    func unavailabilityMessage(for track: QobuzTrack) -> String? { availabilityPolicy.unavailabilityMessage(for: track) }
    func errorMessage(_ error: Error) -> String { availabilityPolicy.errorMessage(error) }

    private func configuredClient(operation: String) throws -> any NativeQobuzServicing {
        guard let client else {
            qobuzLog.warning(
                "browse.configuration",
                "Browse operation blocked because Qobuz is not configured",
                metadata: ["operation": operation]
            )
            throw NativeQobuzError.unavailable("Configure Qobuz credentials before \(operation).")
        }
        return client
    }

    private func updatePage(
        _ id: UUID,
        content: BrowsePageContent,
        availability: NativeBrowseAvailability,
        pagination: NativeBrowsePagePagination?
    ) {
        guard let index = path.firstIndex(where: { $0.id == id }) else { return }
        path[index].content = content
        path[index].availability = availability
        path[index].pagination = pagination
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

    private static func collectionCount(_ content: BrowsePageContent) -> Int {
        switch content {
        case .artist(let value): value.albums.count
        case .playlist(let value): value.tracks.count
        case .label(let value): value.albums.count
        case .loading, .album, .track, .error: 0
        }
    }
}
