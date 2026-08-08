import Foundation
import NativeQobuzCore

/// Pure reducer for collection page cursors and de-duplicated content merging.
/// `BrowsePage` remains the only owner of the current loaded collection.
enum NativeBrowsePageReducer {
    static func pagination(
        for content: BrowsePageContent,
        pageSize: Int,
        requestedOffset: Int = 0
    ) throws -> NativeBrowsePagePagination? {
        guard let page = pageInfo(content) else { return nil }
        _ = try QobuzPageCursor.validatedOffset(
            reportedOffset: page.offset,
            requestedOffset: requestedOffset
        )
        let next = QobuzPageCursor.nextOffset(
            reportedOffset: page.offset,
            requestedOffset: requestedOffset,
            rawItemCount: page.count,
            total: page.total,
            requestedLimit: max(page.limit ?? pageSize, 1)
        )
        return NativeBrowsePagePagination(nextOffset: next, total: page.total)
    }

    static func append(
        _ next: BrowsePageContent,
        to current: BrowsePageContent,
        pageSize: Int,
        requestedOffset: Int
    ) throws -> NativeBrowsePageLoad {
        let merged: BrowsePageContent
        switch (current, next) {
        case (.artist(let first), .artist(let page)):
            var known = Set(first.albums.map(\.id))
            let albums = first.albums + page.albums.filter { known.insert($0.id).inserted }
            merged = .artist(QobuzArtistCatalog(
                id: first.id,
                name: first.name,
                image: first.image ?? page.image,
                albums: albums,
                albumsTotal: first.albumsTotal ?? page.albumsTotal,
                albumsOffset: 0,
                albumsLimit: page.albumsLimit ?? pageSize
            ))
        case (.playlist(let first), .playlist(let page)):
            // Playlist positions are semantic. The same Qobuz track may occur
            // more than once and every occurrence must remain visible.
            let tracks = first.tracks + page.tracks
            merged = .playlist(QobuzPlaylist(
                id: first.id,
                name: first.name,
                tracks: tracks,
                image: first.image ?? page.image,
                owner: first.owner ?? page.owner,
                createdAt: first.createdAt ?? page.createdAt,
                updatedAt: first.updatedAt ?? page.updatedAt,
                duration: first.duration ?? page.duration,
                description: first.playlistDescription ?? page.playlistDescription,
                tracksCount: first.tracksCount ?? page.tracksCount,
                artworkURLs: unique(first.artworkURLs + page.artworkURLs),
                tracksTotal: first.tracksTotal ?? page.tracksTotal,
                tracksOffset: 0,
                tracksLimit: page.tracksLimit ?? pageSize
            ))
        case (.label(let first), .label(let page)):
            var known = Set(first.albums.map(\.id))
            let albums = first.albums + page.albums.filter { known.insert($0.id).inserted }
            merged = .label(QobuzLabelCatalog(
                id: first.id,
                name: first.name,
                slug: first.slug ?? page.slug,
                albums: albums,
                albumsTotal: first.albumsTotal ?? page.albumsTotal,
                albumsOffset: 0,
                albumsLimit: page.albumsLimit ?? pageSize
            ))
        default:
            throw NativeQobuzError.invalidResponse("Qobuz returned a mismatched collection page.")
        }
        return NativeBrowsePageLoad(
            content: merged,
            pagination: try pagination(
                for: next,
                pageSize: pageSize,
                requestedOffset: requestedOffset
            )
        )
    }

    private static func pageInfo(
        _ content: BrowsePageContent
    ) -> (offset: Int?, count: Int, total: Int?, limit: Int?)? {
        switch content {
        case .artist(let value):
            (value.albumsOffset, value.albums.count, value.albumsTotal, value.albumsLimit)
        case .playlist(let value):
            (value.tracksOffset, value.tracks.count, value.tracksTotal, value.tracksLimit)
        case .label(let value):
            (value.albumsOffset, value.albums.count, value.albumsTotal, value.albumsLimit)
        case .loading, .album, .track, .error:
            nil
        }
    }

    private static func unique(_ values: [URL]) -> [URL] {
        var known = Set<URL>()
        return values.filter { known.insert($0).inserted }
    }
}
