import NativeQobuzCore
import SwiftUI

struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            placeholderSymbol: "music.note.list",
            title: title,
            subtitle: subtitle,
            metadata: ["\(playableTracks.count) tracks"]
        )) {
            VStack(spacing: 0) {
                if let libraryStatus {
                    HStack {
                        LibraryStatusLabel(status: libraryStatus)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
                    Divider()
                }
                List(playableTracks, id: \.id) { track in
                    TrackListRow(
                        leading: .artist(track.performer?.name ?? "Unknown Artist"),
                        title: track.displayTitle,
                        isExplicit: track.parentalWarning,
                        duration: track.duration,
                        libraryStatus: trackLibraryStatus?(track)
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var playableTracks: [QobuzTrack] {
        tracks.filter(\.streamable)
    }
}
