import NativeQobuzCore
import SwiftUI

struct AlbumPreview: View {
    let album: QobuzAlbum
    var onOpenArtist: (() -> Void)?
    var onOpenLabel: (() -> Void)?
    var onAddTrack: ((QobuzTrack) -> Void)?
    var isTrackQueued: ((QobuzTrack) -> Bool)?
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?
    var trackAvailabilityMessage: ((QobuzTrack) -> String?)?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: album.image?.bestURL,
            title: album.displayTitle,
            subtitle: album.albumArtistDisplayName,
            onSubtitleTap: onOpenArtist,
            metadata: [
                album.releaseDate?.prefix(4).description,
                album.genre,
                trackCountText,
                album.label
            ].compactMap { $0 },
            badges: badges
        )) {
            VStack(spacing: 0) {
                if let label = album.label, onOpenLabel != nil {
                    HStack {
                        Button { onOpenLabel?() } label: {
                            Label(label, systemImage: "building.2")
                        }
                        .buttonStyle(.borderless)
                        .help("Browse \(label)")
                        Spacer()
                    }
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
                List(album.tracks, id: \.id) { track in
                    TrackListRow(
                        leading: .number(track.trackNumber),
                        title: track.displayTitle,
                        isExplicit: track.parentalWarning,
                        duration: track.duration,
                        isQueued: isTrackQueued?(track) ?? false,
                        libraryStatus: trackLibraryStatus?(track),
                        quality: .catalog(album),
                        unavailableReason: trackAvailabilityMessage?(track),
                        add: track.accountAvailabilityIssue == nil
                            ? onAddTrack.map { add in { add(track) } }
                            : nil
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var badges: [QualityBadge.Kind] {
        var result: [QualityBadge.Kind] = [.catalog(album)]
        if album.parentalWarning { result.append(.explicitContent) }
        return result
    }

    private var trackCountText: String {
        let available = album.availableTracks.count
        guard album.unavailableTrackCount > 0 else { return "\(available) tracks" }
        return "\(available) of \(album.tracks.count) tracks available"
    }
}
