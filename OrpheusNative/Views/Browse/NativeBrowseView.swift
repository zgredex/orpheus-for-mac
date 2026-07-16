import NativeQobuzCore
import SwiftUI

struct NativeBrowseView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            NativeBrowseHeader(page: vm.browse.path.last)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            browseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.default, value: vm.browse.path)
        }
    }

    @ViewBuilder private var browseContent: some View {
        if let page = vm.browse.path.last {
            pageContent(page)
        } else if vm.browse.loadingCategories.contains(vm.browse.category) {
            ProgressView("Searching \(vm.browse.category.rawValue.lowercased())...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.browse.errors[vm.browse.category] {
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { vm.retryBrowseSearch() }
            }
        } else {
            switch vm.browse.category {
            case .albums: paginatedResults(albumResults, category: .albums)
            case .artists: paginatedResults(artistResults, category: .artists)
            case .playlists: paginatedResults(playlistResults, category: .playlists)
            case .tracks: paginatedResults(trackResults, category: .tracks)
            }
        }
    }

    private func paginatedResults(
        _ results: [SearchResult],
        category: NativeBrowseCategory
    ) -> some View {
        SearchResultsList(
            results: results,
            emptyCategory: category.rawValue.lowercased(),
            hasMore: vm.browse.canLoadMore(for: category),
            isLoadingMore: vm.browse.isLoadingMore(for: category),
            loadMoreError: vm.browse.loadMoreErrors[category],
            loadMore: { vm.browse.loadMore(for: category) }
        )
    }

    @ViewBuilder private func pageContent(_ page: BrowsePage) -> some View {
        switch page.content {
        case .loading:
            ProgressView("Loading Qobuz metadata...")
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView {
                Label(
                    page.availability.isUnavailable ? "Unavailable for this account" : "Could not load metadata",
                    systemImage: "wifi.exclamationmark"
                )
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { vm.retryBrowsePage() }
            }
        case .album(let album):
            detailPage(page) {
                AlbumPreview(
                    album: album,
                    onOpenArtist: album.artist.id.map { id in { vm.openArtist(id) } },
                    onOpenLabel: album.labelInfo?.id.map { id in { vm.openLabel(id) } },
                    onAddTrack: { track in
                        vm.addRequest(
                            .track(track.id),
                            title: track.displayTitle,
                            subtitle: track.performer?.name ?? album.albumArtistDisplayName,
                            artworkURL: album.image?.bestURL
                        )
                    },
                    isTrackQueued: { track in
                        queuedURLs.contains(QobuzRequest.track(track.id).canonicalURL)
                    },
                    trackLibraryStatus: { vm.library.status(for: $0) },
                    trackAvailabilityMessage: { vm.browse.unavailabilityMessage(for: $0) }
                )
            }
        case .artist(let catalog):
            detailPage(page) {
                ArtistPreview(
                    artist: catalog,
                    actions: AlbumCatalogActions(viewModel: vm),
                    hasMore: page.hasMore,
                    isLoadingMore: page.isLoadingMore,
                    loadMoreError: page.pagination?.errorMessage,
                    loadMore: { vm.browse.loadMoreCurrentPage() }
                )
            }
        case .track(let track):
            detailPage(page) {
                TrackPreview(
                    track: track,
                    onOpenAlbum: track.album.map { summary in { vm.openAlbum(summary.id) } },
                    libraryStatus: vm.library.status(for: track)
                )
            }
        case .playlist(let playlist):
            detailPage(page) {
                PlaylistPreview(
                    playlist: playlist,
                    libraryStatus: vm.library.status(for: playlist.tracks),
                    trackLibraryStatus: { vm.library.status(for: $0) },
                    trackAvailabilityMessage: { vm.browse.unavailabilityMessage(for: $0) },
                    pagination: CatalogPagination(
                        hasMore: page.hasMore,
                        isLoading: page.isLoadingMore,
                        errorMessage: page.pagination?.errorMessage,
                        loadMore: { vm.browse.loadMoreCurrentPage() }
                    )
                )
            }
        case .label(let label):
            detailPage(page) {
                LabelPreview(
                    label: label,
                    actions: AlbumCatalogActions(viewModel: vm),
                    hasMore: page.hasMore,
                    isLoadingMore: page.isLoadingMore,
                    loadMoreError: page.pagination?.errorMessage,
                    loadMore: { vm.browse.loadMoreCurrentPage() }
                )
            }
        }
    }

    private func detailPage<Content: View>(
        _ page: BrowsePage,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            BrowseAvailabilityBanner(availability: page.availability)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var queuedURLs: Set<URL> {
        Set(vm.queue.map(\.canonicalURL))
    }

    private var albumResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browse.albums.map { album in
            SearchResult(
                id: album.id.rawValue,
                artworkURL: album.image?.bestURL,
                title: album.title,
                subtitle: CatalogFormat.albumSubtitle(
                    artist: album.albumArtistDisplayName,
                    metadata: album.catalogMetadata
                ),
                isQueued: queued.contains(QobuzRequest.album(album.id).canonicalURL),
                libraryStatus: vm.library.status(for: album),
                quality: .catalog(album),
                open: { vm.openAlbum(album.id) },
                add: nil
            )
        }
    }

    private var artistResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browse.artists.map { artist in
            SearchResult(
                id: artist.id?.rawValue ?? artist.name,
                artworkURL: artist.image?.bestURL,
                title: artist.name,
                subtitle: "Artist",
                isQueued: artist.id.map { queued.contains(QobuzRequest.artist($0).canonicalURL) } ?? false,
                placeholderSymbol: "person.crop.circle",
                circularArtwork: true,
                open: artist.id.map { id in { vm.openArtist(id) } },
                add: nil
            )
        }
    }

    private var trackResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browse.tracks.map { track in
            SearchResult(
                id: track.id.rawValue,
                artworkURL: track.album?.image?.bestURL,
                title: track.displayTitle,
                subtitle: track.performer?.name ?? track.album?.title ?? "Track",
                isQueued: queued.contains(QobuzRequest.track(track.id).canonicalURL),
                libraryStatus: vm.library.status(for: track),
                quality: .catalog(track),
                open: { vm.openTrack(track.id) },
                add: nil
            )
        }
    }

    private var playlistResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browse.playlists.map { playlist in
            let metadata = playlist.catalogMetadata
            let count = metadata.tracksCount ?? 0
            return SearchResult(
                id: playlist.id.rawValue,
                artworkURL: metadata.artworkURL,
                title: playlist.name,
                subtitle: [playlist.owner?.name, count > 0 ? "\(count) tracks" : nil]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                isQueued: queued.contains(QobuzRequest.playlist(playlist.id).canonicalURL),
                libraryStatus: vm.library.status(for: playlist.tracks),
                placeholderSymbol: "music.note.list",
                open: { vm.openPlaylist(playlist.id) },
                add: nil
            )
        }
    }

}
