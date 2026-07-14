import NativeQobuzCore
import SwiftUI

struct NativeBrowseView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                if let page = vm.browsePath.last {
                    detailHeader(page)
                } else {
                    searchHeader
                    categoryRow
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            browseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.default, value: vm.browsePath)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Results for")
                .foregroundStyle(.secondary)
            Text(vm.browseQuery)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            if vm.isBrowseLoading {
                ProgressView()
                    .controlSize(.small)
            }
            closeButton
        }
    }

    private var categoryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) {
                categoryPicker
                    .frame(width: 430)
                    .clipped()
                Spacer(minLength: DS.Space.m)
                categoryStatus
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                categoryPicker
                    .frame(maxWidth: .infinity)
                    .clipped()
                categoryStatus
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $vm.browseCategory) {
            ForEach(NativeBrowseCategory.allCases) { category in
                Text("\(category.rawValue)  \(vm.browseCountLabel(for: category))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .tag(category)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var categoryStatus: some View {
        Text(vm.browseStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func detailHeader(_ page: BrowsePage) -> some View {
        HStack(spacing: DS.Space.s) {
            Button { vm.browseBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back")
            Text(pageTitle(page))
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            pageAddButton(page)
            closeButton
        }
    }

    private var closeButton: some View {
        Button { vm.closeBrowse() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .help("Close Browse")
    }

    private func pageTitle(_ page: BrowsePage) -> String {
        switch page.content {
        case .loading: "Loading..."
        case .album(let album): album.displayTitle
        case .artist(let catalog): catalog.name
        case .track(let track): track.displayTitle
        case .playlist(let playlist): playlist.name
        case .label(let label): label.name
        case .error: "Could not load"
        }
    }

    @ViewBuilder private func pageAddButton(_ page: BrowsePage) -> some View {
        switch page.content {
        case .album(let album):
            let queued = queuedURLs.contains(QobuzRequest.album(album.id).canonicalURL)
            HStack(spacing: DS.Space.m) {
                if let status = vm.libraryStatus(for: album) {
                    LibraryStatusLabel(status: status)
                }
                Button(queued ? "In Queue" : "Add Album", systemImage: queued ? "checkmark" : "plus") {
                    vm.addRequest(
                        .album(album.id),
                        title: album.displayTitle,
                        subtitle: album.albumArtistDisplayName,
                        artworkURL: album.image?.bestURL
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(queued || !page.availability.allowsQueue)
                .help(page.availability.message ?? "Add this album to the queue")
            }
        case .artist(let artist):
            let queued = queuedURLs.contains(QobuzRequest.artist(artist.id).canonicalURL)
            Button(queued ? "In Queue" : "Add Artist", systemImage: queued ? "checkmark" : "plus") {
                vm.addRequest(
                    .artist(artist.id),
                    title: artist.name,
                    subtitle: "Artist catalog",
                    artworkURL: artist.image?.bestURL
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(queued || !page.availability.allowsQueue)
            .help(page.availability.message ?? "Add this artist catalog to the queue")
        case .track(let track):
            let queued = queuedURLs.contains(QobuzRequest.track(track.id).canonicalURL)
            Button(queued ? "In Queue" : "Add Track", systemImage: queued ? "checkmark" : "plus") {
                vm.addRequest(
                    .track(track.id),
                    title: track.displayTitle,
                    subtitle: track.performer?.name ?? track.album?.title,
                    artworkURL: track.album?.image?.bestURL
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(queued || !page.availability.allowsQueue)
            .help(page.availability.message ?? "Add this track to the queue")
        case .playlist(let playlist):
            let queued = queuedURLs.contains(QobuzRequest.playlist(playlist.id).canonicalURL)
            Button(queued ? "In Queue" : "Add Playlist", systemImage: queued ? "checkmark" : "plus") {
                vm.addRequest(
                    .playlist(playlist.id),
                    title: playlist.name,
                    subtitle: [playlist.owner?.name, "\(playlist.availableTracks.count) available tracks"]
                        .compactMap { $0 }.joined(separator: " · "),
                    artworkURL: playlist.artworkURL
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(queued || !page.availability.allowsQueue)
            .help(page.availability.message ?? "Add this playlist to the queue")
        case .label(let label):
            let queued = queuedURLs.contains(QobuzRequest.label(label.id).canonicalURL)
            Button(queued ? "In Queue" : "Add Label", systemImage: queued ? "checkmark" : "plus") {
                vm.addRequest(
                    .label(label.id),
                    title: label.name,
                    subtitle: "\(label.availableAlbums.count) available albums"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(queued || !page.availability.allowsQueue)
            .help(page.availability.message ?? "Add all available albums from this label")
        case .loading, .error:
            EmptyView()
        }
    }

    @ViewBuilder private var browseContent: some View {
        if let page = vm.browsePath.last {
            pageContent(page)
        } else if vm.loadingBrowseCategories.contains(vm.browseCategory) {
            ProgressView("Searching \(vm.browseCategory.rawValue.lowercased())...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.browseErrors[vm.browseCategory] {
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { vm.retryBrowseSearch() }
            }
        } else {
            switch vm.browseCategory {
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
            hasMore: vm.canLoadMoreBrowseResults(for: category),
            isLoadingMore: vm.isLoadingMoreBrowseResults(for: category),
            loadMoreError: vm.browseLoadMoreErrors[category],
            loadMore: { vm.loadMoreBrowseResults(for: category) }
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
                    trackLibraryStatus: { vm.libraryStatus(for: $0) },
                    trackAvailabilityMessage: { vm.unavailabilityMessage(for: $0) }
                )
            }
        case .artist(let catalog):
            detailPage(page) {
                ArtistPreview(
                    artist: catalog,
                    onOpenAlbum: { album in vm.openAlbum(album.id) },
                    onAddAlbums: vm.addAlbums,
                    isAlbumQueued: { album in
                        queuedURLs.contains(QobuzRequest.album(album.id).canonicalURL)
                    },
                    albumLibraryStatus: { vm.libraryStatus(for: $0) }
                )
            }
        case .track(let track):
            detailPage(page) {
                TrackPreview(
                    track: track,
                    onOpenAlbum: track.album.map { summary in { vm.openAlbum(summary.id) } },
                    libraryStatus: vm.libraryStatus(for: track)
                )
            }
        case .playlist(let playlist):
            detailPage(page) {
                let metadata = playlist.catalogMetadata
                CollectionPreview(
                    title: playlist.name,
                    subtitle: playlist.owner.map { "Playlist by \($0.name)" } ?? "Playlist",
                    tracks: playlist.tracks,
                    artworkURL: metadata.artworkURL,
                    metadata: CatalogFormat.playlistFacts(metadata),
                    collectionDescription: metadata.editorialDescription,
                    libraryStatus: vm.libraryStatus(for: playlist.tracks),
                    trackLibraryStatus: { vm.libraryStatus(for: $0) },
                    trackAvailabilityMessage: { vm.unavailabilityMessage(for: $0) }
                )
            }
        case .label(let label):
            detailPage(page) {
                LabelPreview(
                    label: label,
                    onOpenAlbum: { album in vm.openAlbum(album.id) },
                    onAddAlbums: vm.addAlbums,
                    isAlbumQueued: { album in
                        queuedURLs.contains(QobuzRequest.album(album.id).canonicalURL)
                    },
                    albumLibraryStatus: { vm.libraryStatus(for: $0) }
                )
            }
        }
    }

    private func detailPage<Content: View>(
        _ page: BrowsePage,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            availabilityBanner(page.availability)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func availabilityBanner(_ availability: NativeBrowseAvailability) -> some View {
        switch availability {
        case .partial(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
                .background(Color.orange.opacity(0.08))
        case .unavailable(let message):
            Label(message, systemImage: "nosign")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
                .background(Color.red.opacity(0.08))
        case .checking, .available:
            EmptyView()
        }
    }

    private var queuedURLs: Set<URL> {
        Set(vm.queue.map(\.canonicalURL))
    }

    private var albumResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browseAlbums.map { album in
            SearchResult(
                id: album.id.rawValue,
                artworkURL: album.image?.bestURL,
                title: album.title,
                subtitle: CatalogFormat.albumSubtitle(
                    artist: album.albumArtistDisplayName,
                    metadata: album.catalogMetadata
                ),
                isQueued: queued.contains(QobuzRequest.album(album.id).canonicalURL),
                libraryStatus: vm.libraryStatus(for: album),
                quality: .catalog(album),
                open: { vm.openAlbum(album.id) },
                add: nil
            )
        }
    }

    private var artistResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browseArtists.map { artist in
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
        return vm.browseTracks.map { track in
            SearchResult(
                id: track.id.rawValue,
                artworkURL: track.album?.image?.bestURL,
                title: track.displayTitle,
                subtitle: track.performer?.name ?? track.album?.title ?? "Track",
                isQueued: queued.contains(QobuzRequest.track(track.id).canonicalURL),
                libraryStatus: vm.libraryStatus(for: track),
                quality: .catalog(track),
                open: { vm.openTrack(track.id) },
                add: nil
            )
        }
    }

    private var playlistResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browsePlaylists.map { playlist in
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
                libraryStatus: vm.libraryStatus(for: playlist.tracks),
                placeholderSymbol: "music.note.list",
                open: { vm.openPlaylist(playlist.id) },
                add: nil
            )
        }
    }

}
