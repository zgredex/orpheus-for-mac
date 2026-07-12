import NativeQobuzCore
import SwiftUI

struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text("\(subtitle)  ·  \(playableTracks.count) tracks").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            Divider()
            List(playableTracks, id: \.id) { track in
                HStack {
                    Text(track.performer?.name ?? "Unknown Artist").foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                    Text(track.displayTitle).lineLimit(1)
                    Spacer()
                    Text(Format.duration(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.listStyle(.inset)
        }
    }

    private var playableTracks: [QobuzTrack] {
        tracks.filter(\.streamable)
    }
}
