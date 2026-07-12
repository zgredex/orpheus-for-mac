import NativeQobuzCore
import SwiftUI

struct AlbumPreview: View {
    let album: QobuzAlbum
    var onOpenArtist: (() -> Void)?
    var onAddTrack: ((QobuzTrack) -> Void)?
    var isTrackQueued: ((QobuzTrack) -> Bool)?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: album.image?.bestURL,
            title: album.displayTitle,
            subtitle: album.artist.name,
            onSubtitleTap: onOpenArtist,
            metadata: [
                album.releaseDate?.prefix(4).description,
                album.genre,
                "\(playableTracks.count) tracks",
                album.label
            ].compactMap { $0 },
            badges: badges
        )) {
            List(playableTracks, id: \.id) { track in
                TrackListRow(
                    leading: .number(track.trackNumber),
                    title: track.displayTitle,
                    isExplicit: track.parentalWarning,
                    duration: track.duration,
                    isQueued: isTrackQueued?(track) ?? false,
                    add: onAddTrack.map { add in { add(track) } }
                )
            }
            .listStyle(.inset)
        }
    }

    private var badges: [QualityBadge.Kind] {
        var result: [QualityBadge.Kind] = []
        if album.hiresStreamable {
            result.append(.hiRes(bitDepth: album.maximumBitDepth, samplingRate: album.maximumSamplingRate))
        }
        if album.parentalWarning { result.append(.explicitContent) }
        return result
    }

    private var playableTracks: [QobuzTrack] {
        album.tracks.filter(\.streamable)
    }
}
