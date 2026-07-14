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

/// Keeps catalog facts visually attached to the preview header without forcing
/// it wider than the window. One flow owns quality, status, tag, and award wrap.
struct CatalogMarkerFlowLayout: Layout {
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

struct CatalogMarkerView: View {
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
