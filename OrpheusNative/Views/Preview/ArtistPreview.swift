import NativeQobuzCore
import SwiftUI

struct ArtistPreview: View {
    let artist: QobuzArtistCatalog
    var onOpenAlbum: ((QobuzAlbum) -> Void)?
    var onAddAlbum: ((QobuzAlbum) -> Void)?
    var isAlbumQueued: ((QobuzAlbum) -> Bool)?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: artist.image?.bestURL,
            placeholderSymbol: "person.crop.circle",
            title: artist.name,
            subtitle: "Artist catalog",
            metadata: ["\(artist.albums.count) albums"]
        )) {
            List(artist.albums, id: \.id) { album in
                HStack(spacing: 10) {
                    ArtworkView(url: album.image?.bestURL, size: DS.Artwork.row)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(album.displayTitle).lineLimit(1)
                        Text(album.releaseDate?.prefix(4).description ?? "").font(.rowSubtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if album.hiresStreamable {
                        QualityBadge(kind: .hiRes(bitDepth: nil, samplingRate: nil))
                    }
                    if onAddAlbum != nil {
                        AddToQueueButton(
                            isQueued: isAlbumQueued?(album) ?? false,
                            add: onAddAlbum.map { add in { add(album) } }
                        )
                    } else {
                        Text("\(album.tracks.count) tracks").font(.rowSubtitle).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpenAlbum?(album) }
            }
            .listStyle(.inset)
        }
    }
}
