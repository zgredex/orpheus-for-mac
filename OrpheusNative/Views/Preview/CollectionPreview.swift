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
    var selectedTrackIDs: Set<QobuzID>?
    var onToggleTrackSelection: ((QobuzID) -> Void)?
    var onSelectAllTracks: (() -> Void)?
    var onClearTrackSelection: (() -> Void)?
    var hasMore = false
    var isLoadingMore = false
    var loadMoreError: String?
    var loadMore: (() -> Void)?

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
                    HStack {
                        LibraryStatusLabel(status: libraryStatus)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
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
                            isSelected: selectedTrackIDs.map { $0.contains(track.id) },
                            toggleSelection: onToggleTrackSelection.map { toggle in { toggle(track.id) } }
                        )
                    }
                    if hasMore || isLoadingMore || loadMoreError != nil {
                        CatalogPaginationRow(
                            subject: "tracks",
                            isLoading: isLoadingMore,
                            errorMessage: loadMoreError,
                            loadMore: loadMore
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if let selectedTrackIDs, onToggleTrackSelection != nil {
            HStack(spacing: DS.Space.s) {
                Label(
                    "\(selectedTrackIDs.count) of \(availableTrackCount) selected",
                    systemImage: "checklist"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button("All", action: { onSelectAllTracks?() })
                    .buttonStyle(.borderless)
                    .disabled(selectedTrackIDs.count == availableTrackCount)
                Button("None", action: { onClearTrackSelection?() })
                    .buttonStyle(.borderless)
                    .disabled(selectedTrackIDs.isEmpty)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(Color.secondary.opacity(0.08))
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
