import NativeQobuzCore
import SwiftUI

struct TrackPreview: View {
    let track: QobuzTrack
    var onOpenAlbum: (() -> Void)?
    var libraryStatus: NativeLibraryStatus?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: track.album?.image?.bestURL,
            title: track.displayTitle,
            subtitle: track.performer?.name ?? "Unknown Artist",
            metadata: [track.album?.title, Format.duration(track.duration)].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            },
            badges: [.catalog(track)]
        )) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let libraryStatus {
                    LibraryStatusLabel(status: libraryStatus)
                }
                if let composer = track.composer?.name { LabeledContent("Composer", value: composer) }
                if let isrc = track.isrc { LabeledContent("ISRC", value: isrc) }
                if let copyright = track.catalogMetadata.copyright {
                    LabeledContent("Copyright", value: copyright)
                }
                if let onOpenAlbum {
                    Button("Show Album", systemImage: "square.stack", action: onOpenAlbum)
                        .controlSize(.small)
                        .padding(.top, DS.Space.xs)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
