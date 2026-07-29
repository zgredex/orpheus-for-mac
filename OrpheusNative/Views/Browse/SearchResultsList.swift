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
    var hasMore = false
    var isLoadingMore = false
    var loadMoreError: String?
    var loadMore: (() -> Void)?

    var body: some View {
        List {
            ForEach(results) { result in
                SearchResultRow(result: result)
            }
            if hasMore || isLoadingMore || loadMoreError != nil {
                CatalogPaginationRow(
                    subject: emptyCategory,
                    isLoading: isLoadingMore,
                    errorMessage: loadMoreError,
                    loadMore: loadMore
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if results.isEmpty && !hasMore && !isLoadingMore && loadMoreError == nil {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: SearchResult

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                compactRow
            } else {
                ViewThatFits(in: .horizontal) {
                    regularRow
                        .frame(minWidth: DS.Row.searchRegularMinimumWidth)
                    compactRow
                }
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: DS.Row.searchMinimumHeight)
        .onTapGesture { result.open?() }
    }

    private var regularRow: some View {
        HStack(spacing: DS.Space.m) {
            artwork
            titleBlock
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minWidth: 180)
            .layoutPriority(1)

            statusBlock
            .frame(width: DS.Column.searchStatus, alignment: .trailing)

            qualityBlock
            .frame(width: DS.Column.searchQuality, alignment: .trailing)

            actionBlock
                .frame(width: DS.Column.rowAction, alignment: .center)
        }
    }

    private var compactRow: some View {
        HStack(spacing: DS.Space.m) {
            artwork
            VStack(alignment: .leading, spacing: DS.Space.s) {
                titleBlock
                HStack(spacing: DS.Space.s) {
                    statusBlock
                    qualityBlock
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            actionBlock
        }
        .padding(.vertical, DS.Space.xs)
    }

    private var artwork: some View {
        ArtworkView(
            url: result.artworkURL,
            size: DS.Artwork.result,
            placeholderSymbol: result.placeholderSymbol,
            circular: result.circularArtwork
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(result.title).font(.rowTitle).lineLimit(1)
            Text(result.subtitle).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var statusBlock: some View {
        if let status = result.libraryStatus {
            LibraryStatusLabel(status: status)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder private var qualityBlock: some View {
        if let quality = result.quality {
            QualityBadge(kind: quality)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder private var actionBlock: some View {
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
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
