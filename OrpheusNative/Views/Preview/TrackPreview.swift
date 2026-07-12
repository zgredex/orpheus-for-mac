import NativeQobuzCore
import SwiftUI

struct TrackPreview: View {
    let track: QobuzTrack

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ArtworkView(url: track.album?.image?.bestURL, size: DS.Artwork.hero)
            VStack(alignment: .leading, spacing: 7) {
                Text(track.displayTitle).font(.title2.weight(.semibold))
                Text(track.performer?.name ?? "Unknown Artist").font(.headline).foregroundStyle(.secondary)
                Text(track.album?.title ?? "").foregroundStyle(.secondary)
                if let composer = track.composer?.name { LabeledContent("Composer", value: composer) }
                if let isrc = track.isrc { LabeledContent("ISRC", value: isrc) }
            }
            Spacer()
        }
        .padding(DS.Space.xl)
    }
}
