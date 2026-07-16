import NativeQobuzCore
import SwiftUI

struct PlaylistPreview: View {
    let playlist: QobuzPlaylist
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?
    var trackAvailabilityMessage: ((QobuzTrack) -> String?)?
    var selection: PlaylistTrackSelection?
    var pagination: CatalogPagination?

    var body: some View {
        let metadata = playlist.catalogMetadata
        CollectionPreview(
            title: playlist.name,
            subtitle: playlist.owner.map { "Playlist by \($0.name)" } ?? "Playlist",
            tracks: playlist.tracks,
            artworkURL: metadata.artworkURL,
            metadata: CatalogFormat.playlistFacts(metadata),
            collectionDescription: metadata.editorialDescription,
            libraryStatus: libraryStatus,
            trackLibraryStatus: trackLibraryStatus,
            trackAvailabilityMessage: trackAvailabilityMessage,
            selection: selection,
            pagination: pagination
        )
    }
}

struct PlaylistTrackSelection {
    let selectedTrackIDs: Set<QobuzID>
    let toggle: (QobuzID) -> Void
    let selectAll: () -> Void
    let clear: () -> Void
}

struct CatalogPagination {
    let hasMore: Bool
    let isLoading: Bool
    let errorMessage: String?
    let loadMore: () -> Void
}
