import NativeQobuzCore
import SwiftUI

struct AlbumCatalogActions {
    let open: (QobuzAlbum) -> Void
    let add: ([QobuzAlbum]) -> Void
    let isQueued: (QobuzAlbum) -> Bool
    let libraryStatus: (QobuzAlbum) -> NativeLibraryStatus?

    @MainActor init(viewModel: NativeViewModel) {
        open = { viewModel.openAlbum($0.id) }
        add = viewModel.addAlbums
        isQueued = { album in
            viewModel.queue.contains {
                $0.canonicalURL == QobuzRequest.album(album.id).canonicalURL
            }
        }
        libraryStatus = { viewModel.library.status(for: $0) }
    }
}

struct AlbumCatalogSelectionBar: View {
    let albums: [QobuzAlbum]
    let queuedIDs: Set<QobuzID>
    @Binding var selectedIDs: Set<QobuzID>
    let add: ([QobuzAlbum]) -> Void

    private var selectedAlbums: [QobuzAlbum] {
        albums.filter { selectedIDs.contains($0.id) && !queuedIDs.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Menu {
                Button("Select All", systemImage: "checklist") {
                    selectedIDs = Set(albums.map(\.id)).subtracting(queuedIDs)
                }
                Button("Clear Selection", systemImage: "xmark") {
                    selectedIDs.removeAll()
                }
            } label: {
                Label(
                    selectedAlbums.isEmpty ? "Select Albums" : "\(selectedAlbums.count) selected",
                    systemImage: "checklist"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                add(selectedAlbums)
                selectedIDs.removeAll()
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

struct SelectableAlbumRow: View {
    let album: QobuzAlbum
    let metadata: String
    let queued: Bool
    let libraryStatus: NativeLibraryStatus?
    @Binding var selectedIDs: Set<QobuzID>
    let open: () -> Void

    private var isSelected: Bool { selectedIDs.contains(album.id) && !queued }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Button(action: toggleSelection) {
                Image(systemName: queued ? "checkmark.circle.fill" : isSelected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(queued ? .secondary : isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(queued)
            .help(queued ? "Already in queue" : isSelected ? "Deselect album" : "Select album")

            Button(action: open) {
                HStack(spacing: DS.Space.m) {
                    ArtworkView(url: album.image?.bestURL, size: DS.Artwork.row)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(album.displayTitle)
                            .font(.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(metadata)
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
            if let libraryStatus {
                LibraryStatusLabel(status: libraryStatus, compact: true)
            }
            if queued {
                Text("Queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private func toggleSelection() {
        if !selectedIDs.insert(album.id).inserted {
            selectedIDs.remove(album.id)
        }
    }
}
