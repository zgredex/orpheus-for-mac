import SwiftUI

/// Header configuration shared by the album/track/playlist/artist previews.
struct PreviewHeader {
    var artworkURL: URL?
    var placeholderSymbol = "music.note"
    var title: String
    var subtitle: String?
    /// Parts joined with "  ·  " on a single caption line.
    var metadata: [String] = []
}

struct PreviewScaffold<Content: View>: View {
    let header: PreviewHeader
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DS.Space.l) {
                ArtworkView(url: header.artworkURL, size: DS.Artwork.hero, placeholderSymbol: header.placeholderSymbol)
                VStack(alignment: .leading, spacing: 5) {
                    Text(header.title).font(.title2.weight(.semibold)).lineLimit(2)
                    if let subtitle = header.subtitle {
                        Text(subtitle).font(.headline).foregroundStyle(.secondary)
                    }
                    if !header.metadata.isEmpty {
                        Text(header.metadata.joined(separator: "  ·  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
