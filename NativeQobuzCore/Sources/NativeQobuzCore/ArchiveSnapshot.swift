import Foundation

public struct QobuzArchiveSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let rootPath: String
    public let scannedAt: Date
    public let tracks: [QobuzArchiveTrack]
    public let issues: [QobuzArchiveIssue]
    public let collections: [QobuzLibraryCollectionRecord]
    public let index: QobuzArchiveLookupIndex

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
        index = QobuzArchiveLookupIndex(
            tracks: tracks,
            issues: issues,
            collections: collections
        )
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
        issues = try container.decode([QobuzArchiveIssue].self, forKey: .issues)
        collections = try container.decode([QobuzLibraryCollectionRecord].self, forKey: .collections)
        index = QobuzArchiveLookupIndex(
            tracks: tracks,
            issues: issues,
            collections: collections
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(scannedAt, forKey: .scannedAt)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(issues, forKey: .issues)
        try container.encode(collections, forKey: .collections)
    }

    public var library: QobuzArchiveLibrary { index.library }
    public var albumCount: Int { index.count(of: .album) }
    public var standaloneTrackCount: Int { index.count(of: .track) }
    public var playlistCount: Int { index.count(of: .playlist) }
    public var unclassifiedCount: Int { index.count(of: .unclassified) }
    public var verifiedCount: Int { index.verifiedCount }
    public var problemCount: Int { index.problemCount }

    public func coverage(trackIDs: [QobuzID], albumID: QobuzID? = nil) -> QobuzArchiveCoverage {
        index.coverage(trackIDs: trackIDs, albumID: albumID)
    }

    public func coverage(trackID: QobuzID, albumID: QobuzID? = nil) -> QobuzArchiveCoverage {
        coverage(trackIDs: [trackID], albumID: albumID)
    }

    public func coverage(albumID: QobuzID) -> QobuzArchiveCoverage {
        index.coverage(albumID: albumID)
    }
}
