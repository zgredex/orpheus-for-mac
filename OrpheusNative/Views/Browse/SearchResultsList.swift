import SwiftUI

/// Display model one search hit maps into, regardless of category.
struct SearchResult: Identifiable {
    let id: String
    let artworkURL: URL?
    let title: String
    let subtitle: String
    let isQueued: Bool
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
            ArtworkView(url: result.artworkURL, size: DS.Artwork.result)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(result.title).font(.rowTitle).lineLimit(1)
                Text(result.subtitle).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: { result.add?() }) { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(result.add == nil)
                .help("Add to queue")
        }
        .contentShape(Rectangle())
        .frame(minHeight: 52)
    }
}
