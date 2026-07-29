import SwiftUI

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

struct PreviewScaffold<HeaderAccessory: View, Content: View>: View {
    let header: PreviewHeader
    private let headerAccessory: HeaderAccessory
    private let hasHeaderAccessory: Bool
    private let content: Content

    init(
        header: PreviewHeader,
        @ViewBuilder content: () -> Content
    ) where HeaderAccessory == EmptyView {
        self.header = header
        headerAccessory = EmptyView()
        hasHeaderAccessory = false
        self.content = content()
    }

    init(
        header: PreviewHeader,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.headerAccessory = headerAccessory()
        hasHeaderAccessory = true
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
                .padding(DS.Space.l)
            Divider()
            content
        }
    }

    @ViewBuilder private var previewHeader: some View {
        if hasHeaderAccessory {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    artwork
                    headerDetails
                        .frame(
                            minWidth: DS.Preview.headerDetailsMinimumWidth,
                            idealWidth: DS.Preview.headerDetailsIdealWidth,
                            maxWidth: DS.Preview.headerDetailsMaximumWidth,
                            alignment: .leading
                        )
                    headerAccessory
                        .frame(
                            minWidth: DS.Preview.headerAccessoryMinimumWidth,
                            idealWidth: DS.Preview.headerAccessoryIdealWidth,
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                }
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    standardHeader
                    headerAccessory
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            standardHeader
        }
    }

    private var standardHeader: some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            artwork
            headerDetails
            Spacer()
        }
    }

    private var artwork: some View {
        ArtworkView(
            url: header.artworkURL,
            size: DS.Artwork.hero,
            placeholderSymbol: header.placeholderSymbol
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var headerDetails: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
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
    }
}
