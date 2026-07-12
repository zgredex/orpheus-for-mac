import NativeQobuzCore
import SwiftUI

struct AlbumPreview: View {
    let album: QobuzAlbum

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: album.image?.bestURL,
            title: album.displayTitle,
            subtitle: album.artist.name,
            metadata: [
                album.releaseDate?.prefix(4).description,
                album.genre,
                "\(playableTracks.count) tracks",
                album.label
            ].compactMap { $0 }
        )) {
            List(playableTracks, id: \.id) { track in
                TrackListRow(leading: .number(track.trackNumber), title: track.displayTitle, duration: track.duration)
            }
            .listStyle(.inset)
        }
    }

    private var playableTracks: [QobuzTrack] {
        album.tracks.filter(\.streamable)
    }
}
