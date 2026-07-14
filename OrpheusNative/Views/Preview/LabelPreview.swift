import NativeQobuzCore
import SwiftUI

struct LabelPreview: View {
    let label: QobuzLabelCatalog
    var onOpenAlbum: ((QobuzAlbum) -> Void)?
    var onAddAlbums: (([QobuzAlbum]) -> Void)?
    var isAlbumQueued: ((QobuzAlbum) -> Bool)?
    var albumLibraryStatus: ((QobuzAlbum) -> NativeLibraryStatus?)?

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
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Available Albums",
                        systemImage: "nosign",
                        description: Text("This label has no albums available for the connected account region.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(albums, id: \.id) { album in albumRow(album) }
                        .listStyle(.inset)
                }
            }
        }
        .onAppear { resetSelection() }
        .onChange(of: label.id) { _, _ in resetSelection() }
    }

    @ViewBuilder private var selectionBar: some View {
        if onAddAlbums != nil {
            HStack(spacing: DS.Space.m) {
                Menu {
                    Button("Select All", systemImage: "checklist") {
                        selectedAlbumIDs = Set(albums.map(\.id)).subtracting(queuedAlbumIDs)
                    }
                    Button("Clear Selection", systemImage: "xmark") { selectedAlbumIDs.removeAll() }
                } label: {
                    Label(selectedAlbums.isEmpty ? "Select Albums" : "\(selectedAlbums.count) selected", systemImage: "checklist")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button {
                    onAddAlbums?(selectedAlbums)
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

    private func albumRow(_ album: QobuzAlbum) -> some View {
        let queued = isAlbumQueued?(album) ?? false
        let selected = selectedAlbumIDs.contains(album.id) && !queued
        return HStack(spacing: 10) {
            Button {
                if !selectedAlbumIDs.insert(album.id).inserted { selectedAlbumIDs.remove(album.id) }
            } label: {
                Image(systemName: queued ? "checkmark.circle.fill" : selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(queued ? .secondary : selected ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(queued)

            Button { onOpenAlbum?(album) } label: {
                HStack(spacing: 10) {
                    ArtworkView(url: album.image?.bestURL, size: DS.Artwork.row)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(album.displayTitle).font(.rowTitle).foregroundStyle(.primary).lineLimit(1)
                        Text(albumMetadata(album)).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            QualityBadge(kind: .catalog(album))
            if let status = albumLibraryStatus?(album) { LibraryStatusLabel(status: status, compact: true) }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private var albums: [QobuzAlbum] { label.availableAlbums }
    private var queuedAlbumIDs: Set<QobuzID> {
        Set(albums.filter { isAlbumQueued?($0) ?? false }.map(\.id))
    }
    private var selectedAlbums: [QobuzAlbum] {
        albums.filter { selectedAlbumIDs.contains($0.id) && !queuedAlbumIDs.contains($0.id) }
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
