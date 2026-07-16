import NativeQobuzCore

struct NativeBrowsePageLoad: Equatable {
    let content: BrowsePageContent
    let pagination: NativeBrowsePagePagination?
}

/// Fetches only the first visible slice for large collection detail pages.
/// Download resolution continues using the core service's exhaustive methods.
struct NativeBrowsePageLoader {
    static let pageSize = 100
    let client: any NativeQobuzServicing

    func initial(_ destination: BrowseDestination) async throws -> NativeBrowsePageLoad {
        let content: BrowsePageContent
        switch destination {
        case .album(let id): content = .album(try await client.album(id: id))
        case .track(let id): content = .track(try await client.track(id: id))
        case .artist(let id):
            content = .artist(try await client.artistPage(id: id, offset: 0, limit: Self.pageSize))
        case .playlist(let id):
            content = .playlist(try await client.playlistPage(id: id, offset: 0, limit: Self.pageSize))
        case .label(let id):
            content = .label(try await client.labelPage(id: id, offset: 0, limit: Self.pageSize))
        }
        return NativeBrowsePageLoad(
            content: content,
            pagination: NativeBrowsePageReducer.pagination(for: content, pageSize: Self.pageSize)
        )
    }

    func next(_ destination: BrowseDestination, offset: Int) async throws -> BrowsePageContent {
        switch destination {
        case .artist(let id):
            return .artist(try await client.artistPage(id: id, offset: offset, limit: Self.pageSize))
        case .playlist(let id):
            return .playlist(try await client.playlistPage(id: id, offset: offset, limit: Self.pageSize))
        case .label(let id):
            return .label(try await client.labelPage(id: id, offset: offset, limit: Self.pageSize))
        case .album, .track:
            throw NativeQobuzError.invalidResponse("This browse page does not support collection pagination.")
        }
    }
}
