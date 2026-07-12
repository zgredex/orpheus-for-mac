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
                AlbumPreview(album: album)
            case .track(let track):
                TrackPreview(track: track)
            case .playlist(let playlist):
                CollectionPreview(title: playlist.name, subtitle: "Playlist", tracks: playlist.tracks)
            case .artist(let artist):
                ArtistPreview(artist: artist)
            case .error(let message):
                ContentUnavailableView("Could not load metadata", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .animation(.default, value: vm.preview)
    }
}
