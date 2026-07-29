import NativeQobuzCore
import SwiftUI

struct NativeBrowseHeader: View {
    @EnvironmentObject private var vm: NativeViewModel
    @EnvironmentObject private var browse: NativeBrowseController
    @EnvironmentObject private var queue: NativeQueueController
    @EnvironmentObject private var library: NativeLibraryController
    let page: BrowsePage?

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if let page {
                detailHeader(page)
            } else {
                searchHeader
                categoryRow
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Results for")
                .foregroundStyle(.secondary)
            Text(browse.query)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            if browse.isLoading {
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
                    .frame(width: DS.Column.categoryPicker)
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
        Picker(
            "Category",
            selection: Binding(
                get: { browse.category },
                set: { browse.category = $0 }
            )
        ) {
            ForEach(NativeBrowseCategory.allCases) { category in
                Text("\(category.rawValue)  \(browse.countLabel(for: category))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .tag(category)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var categoryStatus: some View {
        Text(browse.statusText)
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
                if let status = library.status(for: album) {
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

    private var queuedURLs: Set<URL> {
        Set(queue.items.map(\.canonicalURL))
    }
}
