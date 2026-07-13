import SwiftUI

/// Display model one search hit maps into, regardless of category.
struct SearchResult: Identifiable {
    let id: String
    let artworkURL: URL?
    let title: String
    let subtitle: String
    let isQueued: Bool
    var libraryStatus: NativeLibraryStatus?
    var quality: QualityBadge.Kind?
    var placeholderSymbol = "music.note"
    var circularArtwork = false
    /// Drill into the item (album page, artist page, or a track's album).
    var open: (() -> Void)?
    /// `nil` when the result cannot be added (e.g. an artist without an id).
    let add: (() -> Void)?
}

struct SearchResultsList: View {
    let results: [SearchResult]
    let emptyCategory: String

    var body: some View {
        List(results) { result in
            SearchResultRow(result: result)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(
                    "No \(emptyCategory) found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different artist, album, or track name.")
                )
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(
                url: result.artworkURL,
                size: DS.Artwork.result,
                placeholderSymbol: result.placeholderSymbol,
                circular: result.circularArtwork
            )
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(result.title).font(.rowTitle).lineLimit(1)
                Text(result.subtitle).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let status = result.libraryStatus {
                LibraryStatusLabel(status: status)
            }
            if let quality = result.quality {
                QualityBadge(kind: quality)
            }
            if let add = result.add {
                Button(action: add) { Image(systemName: result.isQueued ? "checkmark" : "plus") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(result.isQueued)
                    .help(result.isQueued ? "Already in queue" : "Add to queue")
            } else if result.open != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 52)
        .onTapGesture { result.open?() }
    }
}
