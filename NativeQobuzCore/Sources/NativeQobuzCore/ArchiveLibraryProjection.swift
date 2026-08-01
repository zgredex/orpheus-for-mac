import Foundation

/// The sole projection from physical archive records into user-facing downloads.
/// A physical track remains singular even when several logical collections refer to it.
public struct QobuzArchiveLibrary: Equatable, Sendable {
    public let entries: [QobuzArchiveEntry]

    public init(
        tracks: [QobuzArchiveTrack],
        collections: [QobuzLibraryCollectionRecord] = []
    ) {
        // Decoded snapshots reject duplicate paths. Keep this projection total as
        // well so a malformed value assembled by a caller can never crash the UI.
        var tracksByPath: [String: QobuzArchiveTrack] = [:]
        var uniqueTracks: [QobuzArchiveTrack] = []
        for track in tracks where tracksByPath[track.relativePath] == nil {
            tracksByPath[track.relativePath] = track
            uniqueTracks.append(track)
        }
        let logicalEntries = collections.compactMap { record -> QobuzArchiveEntry? in
            let values = record.trackPaths.compactMap { tracksByPath[$0] }
            guard !values.isEmpty else { return nil }
            return QobuzArchiveEntry(
                id: record.id,
                kind: record.kind,
                title: record.title,
                subtitle: record.subtitle,
                relativePath: record.relativePath,
                tracks: values
            )
        }
        let referencedPaths = Set(collections.flatMap(\.trackPaths))
        // The root collection manifest is presentation metadata, not ownership
        // of the physical archive. If it is missing or quarantined, every
        // unreferenced track must remain visible through the fallback projection.
        let fallbackTracks = uniqueTracks.filter { !referencedPaths.contains($0.relativePath) }
        let grouped = Dictionary(grouping: fallbackTracks, by: Self.groupKey)
        let fallbackEntries = grouped.keys.compactMap { key -> QobuzArchiveEntry? in
            guard let values = grouped[key], let first = values.first else { return nil }
            let sortedTracks = values.sorted { $0.relativePath < $1.relativePath }
            let directory = QobuzPathSafety.directoryPath(of: first.relativePath)
            let title: String
            let subtitle: String
            let relativePath: String
            switch first.archiveKind {
            case .album:
                title = QobuzPathSafety.lastComponent(of: directory, fallback: "Album \(first.qobuzAlbumID)")
                let artist = QobuzPathSafety.lastComponent(
                    of: QobuzPathSafety.directoryPath(of: directory),
                    fallback: "Album"
                )
                subtitle = "\(artist) · \(sortedTracks.count) file\(sortedTracks.count == 1 ? "" : "s")"
                relativePath = directory
            case .track:
                title = QobuzPathSafety.filenameStem(of: first.relativePath)
                subtitle = QobuzPathSafety.lastComponent(of: directory, fallback: "Standalone track")
                relativePath = first.relativePath
            case .playlist:
                title = QobuzPathSafety.lastComponent(of: directory, fallback: "Playlist")
                subtitle = "Playlist · \(sortedTracks.count) file\(sortedTracks.count == 1 ? "" : "s")"
                relativePath = directory
            case .unclassified:
                title = QobuzPathSafety.lastComponent(
                    of: directory,
                    fallback: QobuzPathSafety.filenameStem(of: first.relativePath)
                )
                subtitle = "Older download · \(sortedTracks.count) file\(sortedTracks.count == 1 ? "" : "s")"
                relativePath = directory.isEmpty ? first.relativePath : directory
            }
            return QobuzArchiveEntry(
                id: key,
                kind: first.archiveKind,
                title: title,
                subtitle: subtitle,
                relativePath: relativePath,
                tracks: sortedTracks
            )
        }
        entries = (logicalEntries + fallbackEntries).sorted {
            if $0.kind != $1.kind { return Self.kindOrder($0.kind) < Self.kindOrder($1.kind) }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    public func entries(of kind: QobuzArchiveKind) -> [QobuzArchiveEntry] {
        entries.filter { $0.kind == kind }
    }

    public func count(of kind: QobuzArchiveKind) -> Int {
        entries.count { $0.kind == kind }
    }

    private static func groupKey(_ track: QobuzArchiveTrack) -> String {
        switch track.archiveKind {
        case .album: "album|\(track.qobuzAlbumID)"
        case .track: "track|\(track.relativePath)"
        case .playlist: "playlist|\(QobuzPathSafety.directoryPath(of: track.relativePath))"
        case .unclassified: "unclassified|\(QobuzPathSafety.directoryPath(of: track.relativePath))"
        }
    }

    private static func kindOrder(_ kind: QobuzArchiveKind) -> Int {
        switch kind {
        case .album: 0
        case .track: 1
        case .playlist: 2
        case .unclassified: 3
        }
    }
}
