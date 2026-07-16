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
        var failed = NativeQueueItem(request: .playlist(QobuzID("p7")), title: "Late Night Mix")
        failed.subtitle = "Playlist"
        return [ready, downloading, failed]
    }()

    static let activity: NativeDownloadActivity = {
        var operation = NativeDownloadOperation(
            queueID: UUID(),
            activityID: UUID(),
            status: .downloading,
            title: "Midnight Frequencies"
        )
        operation.phase = "Downloading"
        operation.currentTrack = "Carrier Wave"
        operation.progress = 0.62
        operation.completedTracks = 2
        operation.totalTracks = 3
        operation.bytesWritten = 96_400_000
        operation.totalBytes = 154_000_000
        operation.bytesPerSecond = 4_200_000
        return NativeDownloadActivity(operation: operation)
    }()

    static let searchResults: [SearchResult] = [
        SearchResult(id: "1", artworkURL: nil, title: "Midnight Frequencies", subtitle: "The Nocturnes", isQueued: false, add: {}),
        SearchResult(id: "2", artworkURL: nil, title: "Daybreak Sessions", subtitle: "The Nocturnes", isQueued: true, add: {}),
        SearchResult(id: "3", artworkURL: nil, title: "Unlinkable Artist", subtitle: "Artist", isQueued: false, add: nil)
    ]
}

#Preview("Queue rows") {
    List(Array(PreviewSamples.queueItems.enumerated()), id: \.element.id) { offset, item in
        QueueRow(
            item: item,
            status: [
                .ready,
                .downloading,
                .failed("The Qobuz account region does not allow this release.")
            ][offset],
            targetQuality: .hiRes
        )
    }
        .listStyle(.sidebar)
        .frame(width: 300, height: 200)
        .environmentObject(NativeViewModel(paths: NativePaths()))
}

#Preview("Activity row") {
    List { ActivityRow(activity: PreviewSamples.activity, status: .downloading) }
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
