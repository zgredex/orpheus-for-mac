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
        HStack(spacing: DS.Space.m) {
            Picker("Category", selection: $vm.browseCategory) {
                ForEach(NativeBrowseCategory.allCases) { category in
                    Text("\(category.rawValue)  \(vm.browseCount(for: category))")
                        .monospacedDigit()
                        .tag(category)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
            Spacer()
            Text(vm.browseStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
                    vm.addRequest(.album(album.id), title: album.displayTitle, artworkURL: album.image?.bestURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(queued)
            }
        case .artist, .loading, .error:
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
            case .albums: SearchResultsList(results: albumResults, emptyCategory: "albums")
            case .artists: SearchResultsList(results: artistResults, emptyCategory: "artists")
            case .tracks: SearchResultsList(results: trackResults, emptyCategory: "tracks")
            }
        }
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
                Label("Could not load metadata", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { vm.retryBrowsePage() }
            }
        case .album(let album):
            AlbumPreview(
                album: album,
                onOpenArtist: album.artist.id.map { id in { vm.openArtist(id) } },
                onAddTrack: { track in
                    vm.addRequest(.track(track.id), title: track.displayTitle, artworkURL: album.image?.bestURL)
                },
                isTrackQueued: { track in
                    queuedURLs.contains(QobuzRequest.track(track.id).canonicalURL)
                },
                trackLibraryStatus: { vm.libraryStatus(for: $0) }
            )
        case .artist(let catalog):
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
                subtitle: album.artist?.name ?? "Album",
                isQueued: queued.contains(QobuzRequest.album(album.id).canonicalURL),
                libraryStatus: vm.libraryStatus(for: album),
                open: { vm.openAlbum(album.id) },
                add: { vm.addRequest(.album(album.id), title: album.title, artworkURL: album.image?.bestURL) }
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
                add: artist.id.map { id in
                    { vm.addRequest(.artist(id), title: artist.name, artworkURL: artist.image?.bestURL) }
                }
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
                open: track.album.map { summary in { vm.openAlbum(summary.id) } },
                add: { vm.addRequest(.track(track.id), title: track.displayTitle, artworkURL: track.album?.image?.bestURL) }
            )
        }
    }
}
