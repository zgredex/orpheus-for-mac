import Foundation

public enum QobuzArchiveKind: String, Codable, CaseIterable, Equatable, Sendable {
    case album
    case track
    case playlist
    case unclassified
}

public enum QobuzArchiveIntegrity: String, Codable, Equatable, Sendable {
    case verified
    case missing
    case checksumMismatch
    case metadataConflict
    case unreadable
}

public struct QobuzArchiveTrack: Codable, Equatable, Identifiable, Sendable {
    public let relativePath: String
    public let qobuzTrackID: String
    public let qobuzAlbumID: String
    public let formatID: Int
    public let bitDepth: Int?
    public let samplingRate: Double?
    public let expectedSHA256: String
    public let actualSHA256: String?
    public let byteCount: Int64?
    public let modificationDate: Date?
    public let integrity: QobuzArchiveIntegrity
    public let archiveKind: QobuzArchiveKind
    public let isLibraryManaged: Bool

    public var id: String { relativePath }
    public var audioFormat: QobuzAudioFormat? { QobuzAudioFormat(formatID: formatID) }

    public init(
        relativePath: String,
        qobuzTrackID: String,
        qobuzAlbumID: String,
        formatID: Int,
        bitDepth: Int? = nil,
        samplingRate: Double? = nil,
        expectedSHA256: String,
        actualSHA256: String? = nil,
        byteCount: Int64? = nil,
        modificationDate: Date? = nil,
        integrity: QobuzArchiveIntegrity,
        archiveKind: QobuzArchiveKind = .unclassified,
        isLibraryManaged: Bool = false
    ) {
        self.relativePath = relativePath
        self.qobuzTrackID = qobuzTrackID
        self.qobuzAlbumID = qobuzAlbumID
        self.formatID = formatID
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.integrity = integrity
        self.archiveKind = archiveKind
        self.isLibraryManaged = isLibraryManaged
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath, qobuzTrackID, qobuzAlbumID, formatID, bitDepth, samplingRate
        case expectedSHA256, actualSHA256, byteCount, modificationDate, integrity
        case archiveKind, isLibraryManaged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        qobuzTrackID = try container.decode(String.self, forKey: .qobuzTrackID)
        qobuzAlbumID = try container.decode(String.self, forKey: .qobuzAlbumID)
        formatID = try container.decode(Int.self, forKey: .formatID)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        samplingRate = try container.decodeIfPresent(Double.self, forKey: .samplingRate)
        expectedSHA256 = try container.decode(String.self, forKey: .expectedSHA256)
        actualSHA256 = try container.decodeIfPresent(String.self, forKey: .actualSHA256)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        integrity = try container.decode(QobuzArchiveIntegrity.self, forKey: .integrity)
        archiveKind = try container.decodeIfPresent(QobuzArchiveKind.self, forKey: .archiveKind) ?? .unclassified
        isLibraryManaged = try container.decodeIfPresent(Bool.self, forKey: .isLibraryManaged) ?? false
    }
}

public struct QobuzArchiveIssue: Codable, Equatable, Sendable {
    public let relativePath: String
    public let message: String

    public init(relativePath: String, message: String) {
        self.relativePath = relativePath
        self.message = message
    }
}

public struct QobuzArchiveCoverage: Equatable, Sendable {
    public let matchedCount: Int
    public let verifiedCount: Int
    public let problemCount: Int
    public let expectedCount: Int?

    public init(matchedCount: Int, verifiedCount: Int, problemCount: Int, expectedCount: Int?) {
        self.matchedCount = matchedCount
        self.verifiedCount = verifiedCount
        self.problemCount = problemCount
        self.expectedCount = expectedCount
    }

    public var isComplete: Bool {
        guard let expectedCount else { return false }
        return expectedCount > 0 && verifiedCount == expectedCount && problemCount == 0
    }
}

public struct QobuzArchiveEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: QobuzArchiveKind
    public let title: String
    public let subtitle: String
    public let relativePath: String
    public let tracks: [QobuzArchiveTrack]

    public var verifiedCount: Int { tracks.count { $0.integrity == .verified } }
    public var problemCount: Int { tracks.count - verifiedCount }
    public var byteCount: Int64? {
        let unique = Dictionary(grouping: tracks, by: \.relativePath).compactMap { $0.value.first }
        let sizes = unique.compactMap(\.byteCount)
        return sizes.count == unique.count ? sizes.reduce(0, +) : nil
    }

    public init(
        id: String,
        kind: QobuzArchiveKind,
        title: String,
        subtitle: String,
        relativePath: String,
        tracks: [QobuzArchiveTrack]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.relativePath = relativePath
        self.tracks = tracks
    }
}
