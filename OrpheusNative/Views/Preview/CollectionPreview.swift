import NativeQobuzCore
import SwiftUI

struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]
    var artworkURL: URL? = nil
    var metadata: [String] = []
    var collectionDescription: String?
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?
    var trackAvailabilityMessage: ((QobuzTrack) -> String?)?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: artworkURL,
            placeholderSymbol: "music.note.list",
            title: title,
            subtitle: subtitle,
            metadata: metadata + [trackCountText]
        )) {
            VStack(spacing: 0) {
                if let collectionDescription, !collectionDescription.isEmpty {
                    Text(collectionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Space.s)
                    Divider()
                }
                if let libraryStatus {
                    HStack {
                        LibraryStatusLabel(status: libraryStatus)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
                    Divider()
                }
                List(tracks, id: \.id) { track in
                    TrackListRow(
                        leading: .artist(track.performer?.name ?? "Unknown Artist"),
                        title: track.displayTitle,
                        isExplicit: track.parentalWarning,
                        duration: track.duration,
                        libraryStatus: trackLibraryStatus?(track),
                        quality: track.album.map(QualityBadge.Kind.catalog),
                        unavailableReason: trackAvailabilityMessage?(track)
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var trackCountText: String {
        let available = tracks.filter { $0.accountAvailabilityIssue == nil }.count
        guard available != tracks.count else { return "\(available) tracks" }
        return "\(available) of \(tracks.count) tracks available"
    }
}
