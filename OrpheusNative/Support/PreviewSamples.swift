#if DEBUG
import Foundation
import NativeQobuzCore
import SwiftUI

/// Sample data for Xcode canvas previews — never compiled into release builds.
@MainActor
enum PreviewSamples {
    static let album = QobuzAlbum(
        id: QobuzID("abc123"),
        title: "Midnight Frequencies",
        artist: QobuzArtist(id: QobuzID("42"), name: "The Nocturnes"),
        tracks: [
            QobuzTrack(id: QobuzID("t1"), title: "Opening Signal", duration: 214, trackNumber: 1),
            QobuzTrack(id: QobuzID("t2"), title: "Carrier Wave", duration: 187, trackNumber: 2, parentalWarning: true),
            QobuzTrack(id: QobuzID("t3"), title: "Static Bloom", duration: 243, trackNumber: 3)
        ],
        releaseDate: "2024-03-15",
        genre: "Electronic",
        label: "Nightside Records",
        maximumSamplingRate: 96,
        maximumBitDepth: 24,
        hiresStreamable: true
    )

    static let queueItems: [NativeQueueItem] = {
        var ready = NativeQueueItem(request: .album(QobuzID("abc123")), title: "Midnight Frequencies")
        ready.subtitle = "The Nocturnes"
        var downloading = NativeQueueItem(request: .track(QobuzID("t9")), title: "Carrier Wave")
        downloading.subtitle = "Track"
        downloading.status = .downloading
        var failed = NativeQueueItem(request: .playlist(QobuzID("p7")), title: "Late Night Mix")
        failed.subtitle = "Playlist"
        failed.status = .failed("The Qobuz account region does not allow this release.")
        return [ready, downloading, failed]
    }()

    static let activity = NativeDownloadActivity(
        id: UUID(),
        queueID: UUID(),
        title: "Midnight Frequencies",
        status: .downloading,
        phase: "Downloading",
        currentTrack: "Carrier Wave",
        progress: 0.62,
        completedTracks: 2,
        totalTracks: 3,
        bytesWritten: 96_400_000,
        totalBytes: 154_000_000,
        bytesPerSecond: 4_200_000
    )

    static let searchResults: [SearchResult] = [
        SearchResult(id: "1", artworkURL: nil, title: "Midnight Frequencies", subtitle: "The Nocturnes", isQueued: false, add: {}),
        SearchResult(id: "2", artworkURL: nil, title: "Daybreak Sessions", subtitle: "The Nocturnes", isQueued: true, add: {}),
        SearchResult(id: "3", artworkURL: nil, title: "Unlinkable Artist", subtitle: "Artist", isQueued: false, add: nil)
    ]
}

#Preview("Queue rows") {
    List(PreviewSamples.queueItems) { QueueRow(item: $0, targetQuality: .hiRes) }
        .listStyle(.sidebar)
        .frame(width: 300, height: 200)
}

#Preview("Activity row") {
    List { ActivityRow(activity: PreviewSamples.activity) }
        .environmentObject(NativeViewModel(paths: NativePaths()))
        .frame(width: 520, height: 120)
}

#Preview("Album preview") {
    AlbumPreview(album: PreviewSamples.album)
        .frame(width: 620, height: 460)
}

#Preview("Search results") {
    SearchResultsList(results: PreviewSamples.searchResults, emptyCategory: "albums")
        .frame(width: 520, height: 240)
}
#endif
