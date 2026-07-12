import NativeQobuzCore
import SwiftUI

struct NativeBrowseView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
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
                    Button { vm.closeBrowse() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close Browse")
                }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            browseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var browseContent: some View {
        if vm.loadingBrowseCategories.contains(vm.browseCategory) {
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
                add: { vm.addRequest(.album(album.id), title: album.title, artworkURL: album.image?.bestURL) }
            )
        }
    }

    private var artistResults: [SearchResult] {
        let queued = queuedURLs
        return vm.browseArtists.map { artist in
            SearchResult(
                id: artist.id?.rawValue ?? artist.name,
                artworkURL: nil,
                title: artist.name,
                subtitle: "Artist",
                isQueued: artist.id.map { queued.contains(QobuzRequest.artist($0).canonicalURL) } ?? false,
                add: artist.id.map { id in { vm.addRequest(.artist(id), title: artist.name) } }
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
                add: { vm.addRequest(.track(track.id), title: track.displayTitle, artworkURL: track.album?.image?.bestURL) }
            )
        }
    }
}
