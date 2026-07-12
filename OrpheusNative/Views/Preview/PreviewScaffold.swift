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
                    if !header.badges.isEmpty {
                        HStack(spacing: DS.Space.xs) {
                            ForEach(header.badges, id: \.self) { QualityBadge(kind: $0) }
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
