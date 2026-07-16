import NativeQobuzCore
import SwiftUI

struct ArtistPreview: View {
    let artist: QobuzArtistCatalog
    var onOpenAlbum: ((QobuzAlbum) -> Void)?
    var onAddAlbums: (([QobuzAlbum]) -> Void)?
    var isAlbumQueued: ((QobuzAlbum) -> Bool)?
    var albumLibraryStatus: ((QobuzAlbum) -> NativeLibraryStatus?)?
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
        if onAddAlbums != nil {
            HStack(spacing: DS.Space.m) {
                Menu {
                    Button("Select All", systemImage: "checklist") {
                        selectedAlbumIDs = Set(visibleAlbums.map(\.id)).subtracting(queuedAlbumIDs)
                    }
                    Button("Clear Selection", systemImage: "xmark") {
                        selectedAlbumIDs.removeAll()
                    }
                } label: {
                    Label(selectionLabel, systemImage: "checklist")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    let albums = selectedAlbums
                    onAddAlbums?(albums)
                    selectedAlbumIDs.removeAll()
                } label: {
                    Label("Add Selected (\(selectedAlbums.count))", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedAlbums.isEmpty)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
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
        let queued = isAlbumQueued?(album) ?? false
        let selected = selectedAlbumIDs.contains(album.id) && !queued

        return HStack(spacing: 10) {
            Button {
                if !selectedAlbumIDs.insert(album.id).inserted {
                    selectedAlbumIDs.remove(album.id)
                }
            } label: {
                Image(systemName: queued ? "checkmark.circle.fill" : selected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(queued ? .secondary : selected ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(queued)
            .help(queued ? "Already in queue" : selected ? "Deselect album" : "Select album")

            Button {
                onOpenAlbum?(album)
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(url: album.image?.bestURL, size: DS.Artwork.row)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(album.displayTitle)
                            .font(.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(rowMetadata(for: album))
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(album.displayTitle)")

            QualityBadge(kind: .catalog(album))
            if let status = albumLibraryStatus?(album) {
                LibraryStatusLabel(status: status, compact: true)
            }
            if queued {
                Text("Queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private var visibleAlbums: [QobuzAlbum] {
        switch scope {
        case .official: artist.officialAlbums
        case .appearances: artist.appearanceAlbums
        }
    }

    private var queuedAlbumIDs: Set<QobuzID> {
        Set(visibleAlbums.filter { isAlbumQueued?($0) ?? false }.map(\.id))
    }

    private var selectedAlbums: [QobuzAlbum] {
        visibleAlbums.filter { selectedAlbumIDs.contains($0.id) && !queuedAlbumIDs.contains($0.id) }
    }

    private var selectionLabel: String {
        selectedAlbums.isEmpty ? "Select Albums" : "\(selectedAlbums.count) selected"
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
