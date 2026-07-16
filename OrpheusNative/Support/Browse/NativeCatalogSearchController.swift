import Foundation
import NativeQobuzCore

/// Sole owner of catalog-search state and search-result cursors. Detail-page
/// navigation has a separate owner in `NativeBrowseController`.
@MainActor
final class NativeCatalogSearchController: ObservableObject {
    @Published private(set) var query = ""
    @Published var category: NativeBrowseCategory = .albums
    @Published private(set) var results = NativeBrowseResults()
    @Published private(set) var loadingCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var loadingMoreCategories: Set<NativeBrowseCategory> = []
    @Published private(set) var errors: [NativeBrowseCategory: String] = [:]
    @Published private(set) var loadMoreErrors: [NativeBrowseCategory: String] = [:]

    private var client: (any NativeQobuzServicing)?
    private var tasks: [Task<Void, Never>] = []
    private var requestID: UUID?

    var isLoading: Bool { !loadingCategories.isEmpty || !loadingMoreCategories.isEmpty }

    var statusText: String {
        if !loadingCategories.isEmpty { return "Searching all categories" }
        let loaded = results.totalCount
        if !loadingMoreCategories.isEmpty { return "\(loaded) loaded · Loading more" }
        if results.hasMoreResults { return "\(loaded) loaded" }
        return loaded == 1 ? "1 result" : "\(loaded) results"
    }

    func configure(client: (any NativeQobuzServicing)?) {
        self.client = client
    }

    func search(_ value: String) throws {
        let client = try configuredClient()
        cancelTasks()
        let id = UUID()
        requestID = id
        query = value
        results = NativeBrowseResults()
        errors = [:]
        loadMoreErrors = [:]
        loadingCategories = Set(NativeBrowseCategory.allCases)
        loadingMoreCategories = []
        category = .albums
        qobuzLog.notice(
            "browse.search",
            "Catalog search started",
            metadata: [
                "searchID": id.uuidString,
                "query": value,
                "categoryCount": String(NativeBrowseCategory.allCases.count)
            ]
        )
        for category in NativeBrowseCategory.allCases {
            tasks.append(initialTask(client: client, query: value, category: category, requestID: id))
        }
    }

    func retry() throws {
        guard !query.isEmpty else { return }
        let selected = category
        try search(query)
        category = selected
    }

    func loadMore(for category: NativeBrowseCategory) {
        guard let client,
              let id = requestID,
              let offset = results.nextOffset(for: category),
              !loadingMoreCategories.contains(category),
              !query.isEmpty else { return }
        let query = query
        loadingMoreCategories.insert(category)
        loadMoreErrors.removeValue(forKey: category)
        qobuzLog.info(
            "browse.pagination",
            "Loading next search result page",
            metadata: Self.searchMetadata(id: id, query: query, category: category, offset: offset)
        )
        tasks.append(Task { [weak self] in
            do {
                let metadata = Self.searchMetadata(id: id, query: query, category: category, offset: offset)
                let page = try await QobuzLogScope.withValue(metadata) {
                    try await client.search(query, category: category.coreValue, limit: 30, offset: offset)
                }
                guard let self, requestID == id, self.query == query, !Task.isCancelled else { return }
                results.append(page, for: category)
                loadingMoreCategories.remove(category)
                qobuzLog.info(
                    "browse.pagination",
                    "Next search result page loaded",
                    metadata: [
                        "searchID": id.uuidString,
                        "category": category.rawValue,
                        "offset": String(offset),
                        "nextOffset": page.nextOffset.map(String.init) ?? "none",
                        "loadedTotal": String(results.count(for: category))
                    ]
                )
            } catch {
                guard let self, requestID == id, self.query == query, !Task.isCancelled else { return }
                loadingMoreCategories.remove(category)
                loadMoreErrors[category] = error.localizedDescription
                qobuzLog.error(
                    "browse.pagination",
                    "Next search result page failed",
                    metadata: Self.searchMetadata(id: id, query: query, category: category, offset: offset),
                    error: error
                )
            }
        })
    }

    func reset() {
        cancelTasks()
        requestID = nil
        query = ""
        category = .albums
        results = NativeBrowseResults()
        errors = [:]
        loadMoreErrors = [:]
        loadingCategories = []
        loadingMoreCategories = []
    }

    func countLabel(for category: NativeBrowseCategory) -> String {
        let loaded = results.count(for: category)
        return "\(loaded)\(results.nextOffset(for: category) == nil ? "" : "+")"
    }

    func canLoadMore(for category: NativeBrowseCategory) -> Bool {
        results.nextOffset(for: category) != nil
    }

    private func initialTask(
        client: any NativeQobuzServicing,
        query: String,
        category: NativeBrowseCategory,
        requestID: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                let metadata = Self.searchMetadata(id: requestID, query: query, category: category, offset: 0)
                let page = try await QobuzLogScope.withValue(metadata) {
                    try await client.search(query, category: category.coreValue, limit: 30, offset: 0)
                }
                guard let self, self.requestID == requestID, !Task.isCancelled else { return }
                apply(page, category: category)
                qobuzLog.info(
                    "browse.search",
                    "Search category loaded",
                    metadata: [
                        "searchID": requestID.uuidString,
                        "category": category.rawValue,
                        "loadedCount": String(results.count(for: category)),
                        "totalCount": page.total.map(String.init) ?? "unknown"
                    ]
                )
            } catch {
                guard let self, self.requestID == requestID, !Task.isCancelled else { return }
                loadingCategories.remove(category)
                errors[category] = error.localizedDescription
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
            }
        }
    }

    private func apply(_ page: QobuzSearchResults, category: NativeBrowseCategory) {
        results.replace(page, for: category)
        loadingCategories.remove(category)
        if loadingCategories.isEmpty, self.category == .albums, results.albums.isEmpty {
            self.category = results.firstNonemptyCategory ?? .albums
        }
    }

    private func configuredClient() throws -> any NativeQobuzServicing {
        guard let client else {
            qobuzLog.warning(
                "browse.search",
                "Catalog search blocked because Qobuz is not configured"
            )
            throw NativeQobuzError.unavailable("Configure Qobuz credentials before searching.")
        }
        return client
    }

    private func cancelTasks() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private static func searchMetadata(
        id: UUID,
        query: String,
        category: NativeBrowseCategory,
        offset: Int
    ) -> [String: String] {
        [
            "searchID": id.uuidString,
            "category": category.rawValue,
            "offset": String(offset),
            "query": query
        ]
    }
}
