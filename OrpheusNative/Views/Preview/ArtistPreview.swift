import NativeQobuzCore
import SwiftUI

struct ArtistPreview: View {
    let artist: QobuzArtistCatalog

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name).font(.title2.weight(.semibold))
                    Text("Artist catalog  ·  \(artist.albums.count) albums").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            Divider()
            List(artist.albums, id: \.id) { album in
                HStack(spacing: 10) {
                    ArtworkView(url: album.image?.bestURL, size: DS.Artwork.row)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(album.displayTitle).lineLimit(1)
                        Text(album.releaseDate?.prefix(4).description ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(album.tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.inset)
        }
    }
}
