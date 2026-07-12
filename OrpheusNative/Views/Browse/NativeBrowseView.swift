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
            case .albums: AlbumSearchList(albums: vm.browseAlbums)
            case .artists: ArtistSearchList(artists: vm.browseArtists)
            case .tracks: TrackSearchList(tracks: vm.browseTracks)
            }
        }
    }
}

private struct AlbumSearchList: View {
    @EnvironmentObject private var vm: NativeViewModel
    let albums: [QobuzAlbumSummary]
    var body: some View {
        List(albums, id: \.id) { album in
            SearchRow(artwork: album.image?.bestURL, title: album.title, subtitle: album.artist?.name ?? "Album") {
                vm.addRequest(.album(album.id), title: album.title)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if albums.isEmpty { emptyResults("albums") } }
    }
}

private struct ArtistSearchList: View {
    @EnvironmentObject private var vm: NativeViewModel
    let artists: [QobuzArtist]
    var body: some View {
        List(artists, id: \.id) { artist in
            SearchRow(artwork: nil, title: artist.name, subtitle: "Artist") {
                if let id = artist.id { vm.addRequest(.artist(id), title: artist.name) }
            }
            .disabled(artist.id == nil)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if artists.isEmpty { emptyResults("artists") } }
    }
}

private struct TrackSearchList: View {
    @EnvironmentObject private var vm: NativeViewModel
    let tracks: [QobuzTrack]
    var body: some View {
        List(tracks, id: \.id) { track in
            SearchRow(artwork: track.album?.image?.bestURL, title: track.displayTitle, subtitle: track.performer?.name ?? track.album?.title ?? "Track") {
                vm.addRequest(.track(track.id), title: track.displayTitle)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if tracks.isEmpty { emptyResults("tracks") } }
    }
}

private struct SearchRow: View {
    let artwork: URL?
    let title: String
    let subtitle: String
    let add: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: artwork, size: DS.Artwork.result)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(.rowTitle).lineLimit(1)
                Text(subtitle).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add to queue")
        }
        .contentShape(Rectangle())
        .frame(minHeight: 52)
    }
}

private func emptyResults(_ category: String) -> some View {
    ContentUnavailableView(
        "No \(category) found",
        systemImage: "magnifyingglass",
        description: Text("Try a different artist, album, or track name.")
    )
}
