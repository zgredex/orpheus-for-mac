import Foundation

/// One construction policy for logical Library records, whether downloaded
/// now or reconstructed later from portable provenance.
public enum QobuzLibraryRecordFactory {
    public static func album(
        qobuzID: String,
        title: String,
        artist: String,
        relativePath: String,
        trackPaths: [String],
        artworkRelativePath: String? = nil,
        description: String? = nil,
        duration: Int? = nil
    ) -> QobuzLibraryCollectionRecord {
        let trackPaths = QobuzLibraryTrackMembership.unique(trackPaths)
        return QobuzLibraryCollectionRecord(
            id: "album|\(qobuzID)",
            kind: .album,
            qobuzID: qobuzID,
            title: title,
            subtitle: "\(artist) · \(trackCountText(trackPaths.count))",
            relativePath: relativePath,
            trackPaths: trackPaths,
            artworkRelativePath: artworkRelativePath,
            collectionDescription: description,
            duration: duration
        )
    }

    public static func track(
        qobuzID: String,
        title: String,
        artist: String,
        relativePath: String,
        artworkRelativePath: String? = nil,
        duration: Int? = nil
    ) -> QobuzLibraryCollectionRecord {
        return QobuzLibraryCollectionRecord(
            id: "track|\(qobuzID)",
            kind: .track,
            qobuzID: qobuzID,
            title: title,
            subtitle: artist,
            relativePath: relativePath,
            trackPaths: [relativePath],
            artworkRelativePath: artworkRelativePath,
            duration: duration
        )
    }

    public static func playlist(
        qobuzID: String,
        title: String,
        owner: String?,
        relativePath: String,
        trackPaths: [String],
        artworkRelativePath: String? = nil,
        description: String? = nil,
        createdAt: Int? = nil,
        updatedAt: Int? = nil,
        duration: Int? = nil,
        sourceTrackCount: Int? = nil
    ) -> QobuzLibraryCollectionRecord {
        return QobuzLibraryCollectionRecord(
            id: "playlist|\(qobuzID)",
            kind: .playlist,
            qobuzID: qobuzID,
            title: title,
            subtitle: "\(owner ?? "Playlist") · \(trackCountText(trackPaths.count))",
            relativePath: relativePath,
            trackPaths: trackPaths,
            artworkRelativePath: artworkRelativePath,
            collectionDescription: description,
            owner: owner,
            createdAt: createdAt,
            updatedAt: updatedAt,
            duration: duration,
            sourceTrackCount: sourceTrackCount
        )
    }

    private static func trackCountText(_ count: Int) -> String {
        "\(count) track\(count == 1 ? "" : "s")"
    }
}
