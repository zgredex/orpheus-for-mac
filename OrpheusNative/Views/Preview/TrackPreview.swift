import NativeQobuzCore
import SwiftUI

struct TrackPreview: View {
    let track: QobuzTrack

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: track.album?.image?.bestURL,
            title: track.displayTitle,
            subtitle: track.performer?.name ?? "Unknown Artist",
            metadata: [track.album?.title].compactMap { $0 }
        )) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let composer = track.composer?.name { LabeledContent("Composer", value: composer) }
                if let isrc = track.isrc { LabeledContent("ISRC", value: isrc) }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
