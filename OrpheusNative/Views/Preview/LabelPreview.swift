import NativeQobuzCore
import SwiftUI

struct LabelPreview: View {
    let label: QobuzLabelCatalog
    var actions: AlbumCatalogActions?
    var hasMore = false
    var isLoadingMore = false
    var loadMoreError: String?
    var loadMore: (() -> Void)?

    @State private var selectedAlbumIDs: Set<QobuzID> = []

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: nil,
            placeholderSymbol: "building.2",
            title: label.name,
            subtitle: "Qobuz label",
            metadata: ["\(albums.count) available albums"]
        )) {
            VStack(spacing: 0) {
                selectionBar
                Divider()
                if albums.isEmpty, !hasMore, !isLoadingMore, loadMoreError == nil {
                    ContentUnavailableView(
                        "No Available Albums",
                        systemImage: "nosign",
                        description: Text("This label has no albums available for the connected account region.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(albums, id: \.id) { album in albumRow(album) }
                        if hasMore || isLoadingMore || loadMoreError != nil {
                            CatalogPaginationRow(
                                subject: "albums",
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
        .onAppear { resetSelection() }
        .onChange(of: label.id) { _, _ in resetSelection() }
    }

    @ViewBuilder private var selectionBar: some View {
        if let actions {
            AlbumCatalogSelectionBar(
                albums: albums,
                queuedIDs: queuedAlbumIDs,
                selectedIDs: $selectedAlbumIDs,
                add: actions.add
            )
        }
    }

    private func albumRow(_ album: QobuzAlbum) -> some View {
        SelectableAlbumRow(
            album: album,
            metadata: albumMetadata(album),
            queued: actions?.isQueued(album) ?? false,
            libraryStatus: actions?.libraryStatus(album),
            selectedIDs: $selectedAlbumIDs,
            open: { actions?.open(album) }
        )
    }

    private var albums: [QobuzAlbum] { label.availableAlbums }
    private var queuedAlbumIDs: Set<QobuzID> {
        Set(albums.filter { actions?.isQueued($0) ?? false }.map(\.id))
    }

    private func resetSelection() {
        selectedAlbumIDs = Set(albums.map(\.id)).subtracting(queuedAlbumIDs)
    }

    private func albumMetadata(_ album: QobuzAlbum) -> String {
        var values = [album.mainArtists.map(\.name).joined(separator: ", ")]
        values.append(contentsOf: CatalogFormat.albumFacts(
            album.catalogMetadata,
            trackCount: album.tracksCount ?? album.tracks.count,
            includeGenre: false
        ))
        return values.joined(separator: "  ·  ")
    }
}
