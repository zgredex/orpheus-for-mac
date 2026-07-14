import SwiftUI

struct CatalogMarker: Hashable {
    enum Kind: Hashable {
        case official
        case unofficial
        case tag
        case award
    }

    let text: String
    let systemImage: String
    let kind: Kind
}

/// Header configuration shared by the album/track/playlist/artist previews.
struct PreviewHeader {
    var artworkURL: URL?
    var placeholderSymbol = "music.note"
    var title: String
    var subtitle: String?
    /// When set, the subtitle renders as a clickable navigation link.
    var onSubtitleTap: (() -> Void)?
    /// Parts joined with "  ·  " on a single caption line.
    var metadata: [String] = []
    var badges: [QualityBadge.Kind] = []
    var catalogMarkers: [CatalogMarker] = []
}

struct PreviewScaffold<Content: View>: View {
    let header: PreviewHeader
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DS.Space.l) {
                ArtworkView(url: header.artworkURL, size: DS.Artwork.hero, placeholderSymbol: header.placeholderSymbol)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(header.title).font(.title2.weight(.semibold)).lineLimit(2)
                    if let subtitle = header.subtitle {
                        if let onSubtitleTap = header.onSubtitleTap {
                            Button(action: onSubtitleTap) {
                                HStack(spacing: 3) {
                                    Text(subtitle)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .help("Show \(subtitle)")
                        } else {
                            Text(subtitle).font(.headline).foregroundStyle(.secondary)
                        }
                    }
                    if !header.metadata.isEmpty {
                        Text(header.metadata.joined(separator: "  ·  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !header.badges.isEmpty || !header.catalogMarkers.isEmpty {
                        CatalogMarkerFlowLayout(spacing: DS.Space.xs) {
                            ForEach(header.badges, id: \.self) { QualityBadge(kind: $0) }
                            ForEach(header.catalogMarkers, id: \.self) { CatalogMarkerView(marker: $0) }
                        }
                        .padding(.top, DS.Space.xxs)
                    }
                }
                Spacer()
            }
            .padding(18)
            Divider()
            content()
        }
    }
}

/// Keeps catalog facts visually attached to the preview header without forcing
/// it wider than the window. The same layout handles quality, status, tag, and
/// award capsules so views do not each invent their own overflow behavior.
private struct CatalogMarkerFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for subview in subviews {
            let item = Item(subview: subview, size: subview.sizeThatFits(.unspecified))
            let nextWidth = row.items.isEmpty ? item.size.width : row.width + spacing + item.size.width
            if nextWidth > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.items.append(item)
            row.width = row.items.count == 1 ? item.size.width : row.width + spacing + item.size.width
            row.height = max(row.height, item.size.height)
        }

        if !row.items.isEmpty { rows.append(row) }
        return rows
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

private struct CatalogMarkerView: View {
    let marker: CatalogMarker

    var body: some View {
        Label(marker.text, systemImage: marker.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay { Capsule().stroke(tint.opacity(0.2), lineWidth: 0.5) }
    }

    private var tint: Color {
        switch marker.kind {
        case .official: .green
        case .unofficial: .orange
        case .tag: .secondary
        case .award: .purple
        }
    }
}
