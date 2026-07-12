import NativeQobuzCore
import SwiftUI

struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            placeholderSymbol: "music.note.list",
            title: title,
            subtitle: subtitle,
            metadata: ["\(playableTracks.count) tracks"]
        )) {
            List(playableTracks, id: \.id) { track in
                TrackListRow(
                    leading: .artist(track.performer?.name ?? "Unknown Artist"),
                    title: track.displayTitle,
                    duration: track.duration
                )
            }
            .listStyle(.inset)
        }
    }

    private var playableTracks: [QobuzTrack] {
        tracks.filter(\.streamable)
    }
}
