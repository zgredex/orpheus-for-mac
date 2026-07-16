import NativeQobuzCore
import SwiftUI

struct ArtistPreview: View {
    let artist: QobuzArtistCatalog
    var actions: AlbumCatalogActions?
    var hasMore = false
    var isLoadingMore = false
    var loadMoreError: String?
    var loadMore: (() -> Void)?

    @State private var scope: ReleaseScope = .official
    @State private var selectedAlbumIDs: Set<QobuzID> = []

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: artist.image?.bestURL,
            placeholderSymbol: "person.crop.circle",
            title: artist.name,
            subtitle: "Discography",
            metadata: [
                "\(artist.officialAlbums.count) official",
                "\(artist.appearanceAlbums.count) appearances"
            ]
        )) {
            VStack(spacing: 0) {
                sectionPicker
                Divider()
                selectionBar
                Divider()
                catalogList
            }
        }
        .onAppear { resetSelection() }
        .onChange(of: artist.id) { _, _ in
            scope = .official
            resetSelection()
        }
        .onChange(of: scope) { _, _ in resetSelection() }
    }

    private var sectionPicker: some View {
        Picker("Discography section", selection: $scope) {
            Text("Official  \(artist.officialAlbums.count)").tag(ReleaseScope.official)
            Text("Appearances  \(artist.appearanceAlbums.count)").tag(ReleaseScope.appearances)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

    @ViewBuilder private var selectionBar: some View {
        if let actions {
            AlbumCatalogSelectionBar(
                albums: visibleAlbums,
                queuedIDs: queuedAlbumIDs,
                selectedIDs: $selectedAlbumIDs,
                add: actions.add
            )
        }
    }

    @ViewBuilder private var catalogList: some View {
        if visibleAlbums.isEmpty, !hasMore, !isLoadingMore, loadMoreError == nil {
            ContentUnavailableView(
                scope.emptyTitle,
                systemImage: scope.emptySymbol,
                description: Text(scope.emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(visibleAlbums, id: \.id) { album in albumRow(album) }
                if hasMore || isLoadingMore || loadMoreError != nil {
                    CatalogPaginationRow(
                        subject: "releases",
                        isLoading: isLoadingMore,
                        errorMessage: loadMoreError,
                        loadMore: loadMore
                    )
                }
            }
            .listStyle(.inset)
        }
    }

    private func albumRow(_ album: QobuzAlbum) -> some View {
        SelectableAlbumRow(
            album: album,
            metadata: rowMetadata(for: album),
            queued: actions?.isQueued(album) ?? false,
            libraryStatus: actions?.libraryStatus(album),
            selectedIDs: $selectedAlbumIDs,
            open: { actions?.open(album) }
        )
    }

    private var visibleAlbums: [QobuzAlbum] {
        switch scope {
        case .official: artist.officialAlbums
        case .appearances: artist.appearanceAlbums
        }
    }

    private var queuedAlbumIDs: Set<QobuzID> {
        Set(visibleAlbums.filter { actions?.isQueued($0) ?? false }.map(\.id))
    }

    private func rowMetadata(for album: QobuzAlbum) -> String {
        var values: [String] = []
        if scope == .appearances { values.append(album.artist.name) }
        values.append(contentsOf: CatalogFormat.albumFacts(
            album.catalogMetadata,
            trackCount: album.tracksCount ?? album.tracks.count,
            label: album.label,
            includeGenre: false
        ))
        return values.joined(separator: "  ·  ")
    }

    private func resetSelection() {
        switch scope {
        case .official:
            selectedAlbumIDs = Set(visibleAlbums.map(\.id)).subtracting(queuedAlbumIDs)
        case .appearances:
            selectedAlbumIDs.removeAll()
        }
    }
}

private enum ReleaseScope: Hashable {
    case official
    case appearances

    var emptyTitle: String {
        switch self {
        case .official: "No Official Releases"
        case .appearances: "No Appearances"
        }
    }

    var emptySymbol: String {
        switch self {
        case .official: "music.note.house"
        case .appearances: "person.2"
        }
    }

    var emptyDescription: String {
        switch self {
        case .official: "Qobuz has no available releases credited to this artist as the primary album artist."
        case .appearances: "Qobuz has no available credited appearances for this artist."
        }
    }
}
