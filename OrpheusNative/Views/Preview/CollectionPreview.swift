import NativeQobuzCore
import SwiftUI

struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]
    var artworkURL: URL? = nil
    var metadata: [String] = []
    var collectionDescription: String?
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?
    var trackAvailabilityMessage: ((QobuzTrack) -> String?)?
    var selection: PlaylistTrackSelection?
    var pagination: CatalogPagination?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: artworkURL,
            placeholderSymbol: "music.note.list",
            title: title,
            subtitle: subtitle,
            metadata: metadata + [trackCountText]
        )) {
            VStack(spacing: 0) {
                EditorialOverview(
                    heading: "About this playlist",
                    summary: nil,
                    editorialDescription: collectionDescription
                )
                if let libraryStatus {
                    PreviewLibraryStatusStrip(status: libraryStatus)
                    Divider()
                }
                selectionBar
                List {
                    ForEach(tracks, id: \.id) { track in
                        TrackListRow(
                            leading: .artist(track.performer?.name ?? "Unknown Artist"),
                            title: track.displayTitle,
                            isExplicit: track.parentalWarning,
                            duration: track.duration,
                            libraryStatus: trackLibraryStatus?(track),
                            quality: .catalog(track),
                            unavailableReason: trackAvailabilityMessage?(track),
                            isSelected: selection.map { $0.selectedTrackIDs.contains(track.id) },
                            toggleSelection: selection.map { selection in { selection.toggle(track.id) } }
                        )
                    }
                    if let pagination,
                       pagination.hasMore || pagination.isLoading || pagination.errorMessage != nil {
                        CatalogPaginationRow(
                            subject: "tracks",
                            isLoading: pagination.isLoading,
                            errorMessage: pagination.errorMessage,
                            loadMore: pagination.loadMore
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if let selection {
            TrackSelectionBar(
                selectedCount: selection.selectedTrackIDs.count,
                availableCount: availableTrackCount,
                selectAll: selection.selectAll,
                clear: selection.clear
            )
            Divider()
        }
    }

    private var trackCountText: String {
        let available = availableTrackCount
        guard available != tracks.count else { return "\(available) tracks" }
        return "\(available) of \(tracks.count) tracks available"
    }

    private var availableTrackCount: Int {
        tracks.filter { $0.accountAvailabilityIssue == nil }.count
    }
}
