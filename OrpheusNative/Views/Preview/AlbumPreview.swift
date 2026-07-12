import NativeQobuzCore
import SwiftUI

struct AlbumPreview: View {
    let album: QobuzAlbum

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DS.Space.l) {
                ArtworkView(url: album.image?.bestURL, size: DS.Artwork.hero)
                VStack(alignment: .leading, spacing: 5) {
                    Text(album.displayTitle).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(album.artist.name).font(.headline).foregroundStyle(.secondary)
                    Text(albumMetadata).font(.caption).foregroundStyle(.secondary)
                    if let label = album.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(18)
            Divider()
            List(playableTracks, id: \.id) { track in
                HStack {
                    Text("\(track.trackNumber ?? 0)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    Text(track.displayTitle).lineLimit(1)
                    Spacer()
                    Text(Format.duration(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private var albumMetadata: String {
        [album.releaseDate?.prefix(4).description, album.genre, "\(playableTracks.count) tracks"]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }

    private var playableTracks: [QobuzTrack] {
        album.tracks.filter(\.streamable)
    }
}
