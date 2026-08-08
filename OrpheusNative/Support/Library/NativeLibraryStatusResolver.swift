import NativeQobuzCore

struct NativeLibraryStatusResolver {
    func status(
        for item: NativeQueueItem,
        snapshot: QobuzArchiveSnapshot?
    ) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        let coverage: QobuzArchiveCoverage
        switch item.request {
        case .track(let id):
            coverage = snapshot.coverage(trackID: id)
        case .album(let id):
            let trackIDs = item.selectedTrackIDs.map(Array.init) ?? item.expectedTrackIDs
            if let trackIDs, !trackIDs.isEmpty {
                coverage = snapshot.coverage(trackIDs: trackIDs, albumID: id)
            } else if item.selectedTrackIDs != nil {
                return nil
            } else {
                coverage = snapshot.coverage(albumID: id)
            }
        case .playlist:
            let trackIDs = item.selectedTrackIDs.map(Array.init) ?? item.expectedTrackIDs
            guard let trackIDs, !trackIDs.isEmpty else { return nil }
            coverage = snapshot.coverage(trackIDs: trackIDs)
        case .artist, .label:
            return nil
        }
        return NativeLibraryStatus(coverage)
    }

    func status(
        for album: QobuzAlbumSummary,
        snapshot: QobuzArchiveSnapshot?
    ) -> NativeLibraryStatus? {
        snapshot.flatMap { NativeLibraryStatus($0.coverage(albumID: album.id)) }
    }

    func status(
        for album: QobuzAlbum,
        snapshot: QobuzArchiveSnapshot?
    ) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        let trackIDs = album.availableTracks.map(\.id)
        let coverage = trackIDs.isEmpty
            ? snapshot.coverage(albumID: album.id)
            : snapshot.coverage(trackIDs: trackIDs, albumID: album.id)
        return NativeLibraryStatus(coverage)
    }

    func status(
        for track: QobuzTrack,
        snapshot: QobuzArchiveSnapshot?
    ) -> NativeLibraryStatus? {
        snapshot.flatMap {
            NativeLibraryStatus($0.coverage(trackID: track.id, albumID: track.album?.id))
        }
    }

    func status(
        for tracks: [QobuzTrack],
        snapshot: QobuzArchiveSnapshot?
    ) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        let trackIDs = tracks.filter { $0.accountAvailabilityIssue == nil }.map(\.id)
        guard !trackIDs.isEmpty else { return nil }
        return NativeLibraryStatus(snapshot.coverage(trackIDs: trackIDs))
    }
}
