import NativeQobuzCore
import SwiftUI

struct NativePreviewView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        Group {
            switch vm.preview {
            case .empty:
                ContentUnavailableView("Select an item", systemImage: "music.note", description: Text("Metadata and tracks appear here."))
            case .loading:
                ProgressView("Loading Qobuz metadata...")
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            case .album(let album):
                AlbumPreview(
                    album: album,
                    onOpenArtist: album.artist.id.map { id in { vm.openArtist(id) } },
                    libraryStatus: vm.libraryStatus(for: album),
                    trackLibraryStatus: { vm.libraryStatus(for: $0) }
                )
            case .track(let track):
                TrackPreview(
                    track: track,
                    onOpenAlbum: track.album.map { summary in { vm.openAlbum(summary.id) } },
                    libraryStatus: vm.libraryStatus(for: track)
                )
            case .playlist(let playlist):
                CollectionPreview(
                    title: playlist.name,
                    subtitle: "Playlist",
                    tracks: playlist.tracks,
                    libraryStatus: vm.libraryStatus(for: playlist.tracks),
                    trackLibraryStatus: { vm.libraryStatus(for: $0) }
                )
            case .artist(let artist):
                ArtistPreview(
                    artist: artist,
                    onOpenAlbum: { album in vm.openAlbum(album.id) },
                    onAddAlbums: vm.addAlbums,
                    isAlbumQueued: { album in
                        vm.queue.contains { $0.canonicalURL == QobuzRequest.album(album.id).canonicalURL }
                    },
                    albumLibraryStatus: { vm.libraryStatus(for: $0) }
                )
            case .error(let message):
                ContentUnavailableView("Could not load metadata", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: vm.preview)
    }
}
