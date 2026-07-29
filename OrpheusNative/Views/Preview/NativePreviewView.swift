import NativeQobuzCore
import SwiftUI

struct NativePreviewView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @EnvironmentObject private var browse: NativeBrowseController
    @EnvironmentObject private var queue: NativeQueueController
    @EnvironmentObject private var preview: NativePreviewController
    @EnvironmentObject private var library: NativeLibraryController

    var body: some View {
        Group {
            switch preview.state {
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
                    onOpenLabel: album.labelInfo?.id.map { id in { vm.openLabel(id) } },
                    libraryStatus: library.status(for: album),
                    trackLibraryStatus: { library.status(for: $0) },
                    trackAvailabilityMessage: { browse.unavailabilityMessage(for: $0) },
                    selectedTrackIDs: vm.queueTrackSelection(for: .album(album.id)),
                    onToggleTrackSelection: vm.toggleSelectedQueueTrack,
                    onSelectAllTracks: vm.selectAllSelectedQueueTracks,
                    onClearTrackSelection: vm.clearSelectedQueueTracks
                )
            case .track(let track):
                TrackPreview(
                    track: track,
                    onOpenAlbum: track.album.map { summary in { vm.openAlbum(summary.id) } },
                    libraryStatus: library.status(for: track)
                )
            case .playlist(let playlist):
                PlaylistPreview(
                    playlist: playlist,
                    libraryStatus: library.status(for: playlist.tracks),
                    trackLibraryStatus: { library.status(for: $0) },
                    trackAvailabilityMessage: { browse.unavailabilityMessage(for: $0) },
                    selection: vm.queueTrackSelection(for: .playlist(playlist.id)).map {
                        PlaylistTrackSelection(
                            selectedTrackIDs: $0,
                            toggle: vm.toggleSelectedQueueTrack,
                            selectAll: vm.selectAllSelectedQueueTracks,
                            clear: vm.clearSelectedQueueTracks
                        )
                    }
                )
            case .artist(let artist):
                ArtistPreview(
                    artist: artist,
                    actions: AlbumCatalogActions(viewModel: vm)
                )
            case .label(let label):
                LabelPreview(
                    label: label,
                    actions: AlbumCatalogActions(viewModel: vm)
                )
            case .error(let message):
                ContentUnavailableView("Could not load metadata", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: preview.state)
    }

}
