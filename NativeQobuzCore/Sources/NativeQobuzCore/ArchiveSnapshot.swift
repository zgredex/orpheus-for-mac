import Foundation

public struct QobuzArchiveSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let rootPath: String
    public let scannedAt: Date
    public let tracks: [QobuzArchiveTrack]
    public let issues: [QobuzArchiveIssue]
    public let collections: [QobuzLibraryCollectionRecord]

    public init(
        version: Int = 1,
        rootPath: String,
        scannedAt: Date = Date(),
        tracks: [QobuzArchiveTrack],
        issues: [QobuzArchiveIssue] = [],
        collections: [QobuzLibraryCollectionRecord] = []
    ) {
        self.version = version
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.tracks = tracks
        self.issues = issues
        self.collections = collections
    }

    private enum CodingKeys: String, CodingKey {
        case version, rootPath, scannedAt, tracks, issues, collections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        tracks = try container.decode([QobuzArchiveTrack].self, forKey: .tracks)
        issues = try container.decodeIfPresent([QobuzArchiveIssue].self, forKey: .issues) ?? []
        collections = try container.decodeIfPresent([QobuzLibraryCollectionRecord].self, forKey: .collections) ?? []
        try validate()
    }

    public var library: QobuzArchiveLibrary { QobuzArchiveLibrary(tracks: tracks, collections: collections) }
    public var albumCount: Int { library.count(of: .album) }
    public var standaloneTrackCount: Int { library.count(of: .track) }
    public var playlistCount: Int { library.count(of: .playlist) }
    public var unclassifiedCount: Int { library.count(of: .unclassified) }
    public var verifiedCount: Int { tracks.count { $0.integrity == .verified } }
    public var problemCount: Int {
        let trackProblemPaths = Set(tracks.filter { $0.integrity != .verified }.map(\.relativePath))
        let standaloneIssues = issues.count { !trackProblemPaths.contains($0.relativePath) }
        return trackProblemPaths.count + standaloneIssues
    }

    public func coverage(trackIDs: [QobuzID], albumID: QobuzID? = nil) -> QobuzArchiveCoverage {
        let expectedIDs = Set(trackIDs.map(\.rawValue))
        let candidates = tracks.filter { track in
            expectedIDs.contains(track.qobuzTrackID)
                && albumID.map { track.qobuzAlbumID == $0.rawValue } != false
        }
        return Self.coverage(for: candidates, expectedCount: expectedIDs.count)
    }

    public func coverage(trackID: QobuzID, albumID: QobuzID? = nil) -> QobuzArchiveCoverage {
        coverage(trackIDs: [trackID], albumID: albumID)
    }

    public func coverage(albumID: QobuzID) -> QobuzArchiveCoverage {
        Self.coverage(
            for: tracks.filter { $0.qobuzAlbumID == albumID.rawValue },
            expectedCount: nil
        )
    }

    private static func coverage(
        for candidates: [QobuzArchiveTrack],
        expectedCount: Int?
    ) -> QobuzArchiveCoverage {
        let groups = Dictionary(grouping: candidates, by: \.qobuzTrackID)
        let verified = groups.values.count { records in records.contains { $0.integrity == .verified } }
        let problems = groups.values.count { records in records.contains { $0.integrity != .verified } }
        return QobuzArchiveCoverage(
            matchedCount: groups.count,
            verifiedCount: verified,
            problemCount: problems,
            expectedCount: expectedCount
        )
    }
}
