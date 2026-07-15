import Foundation

/// Stable facts about the exact downloaded file. This archive record excludes
/// refreshable catalog/UI metadata and portable audio tags.
public struct QobuzFileProvenance: Codable, Equatable, Sendable {
    public let qobuzTrackID: String
    public let qobuzAlbumID: String
    public let formatID: Int
    public let bitDepth: Int?
    public let samplingRate: Double?
    public let sha256: String
    public let archiveKind: QobuzArchiveKind
    public let isLibraryManaged: Bool

    public init(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        sha256: String,
        archiveKind: QobuzArchiveKind? = nil,
        isLibraryManaged: Bool = false
    ) {
        qobuzTrackID = item.track.id.rawValue
        qobuzAlbumID = item.album.id.rawValue
        formatID = fileInfo.formatID
        bitDepth = fileInfo.bitDepth
        samplingRate = fileInfo.samplingRate
        self.sha256 = sha256
        self.archiveKind = archiveKind ?? item.collection.archiveKind
        self.isLibraryManaged = isLibraryManaged
    }

    private enum CodingKeys: String, CodingKey {
        case qobuzTrackID
        case qobuzAlbumID
        case formatID
        case bitDepth
        case samplingRate
        case sha256
        case archiveKind
        case isLibraryManaged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qobuzTrackID = try container.decode(String.self, forKey: .qobuzTrackID)
        qobuzAlbumID = try container.decode(String.self, forKey: .qobuzAlbumID)
        formatID = try container.decode(Int.self, forKey: .formatID)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        samplingRate = try container.decodeIfPresent(Double.self, forKey: .samplingRate)
        sha256 = try container.decode(String.self, forKey: .sha256)
        archiveKind = try container.decodeIfPresent(QobuzArchiveKind.self, forKey: .archiveKind) ?? .unclassified
        isLibraryManaged = try container.decodeIfPresent(Bool.self, forKey: .isLibraryManaged) ?? false
    }

    public func belongs(to item: QobuzResolvedTrack) -> Bool {
        qobuzTrackID == item.track.id.rawValue && qobuzAlbumID == item.album.id.rawValue
    }

    public func matches(item: QobuzResolvedTrack, fileInfo: QobuzFileInfo) -> Bool {
        belongs(to: item)
            && formatID == fileInfo.formatID
            && bitDepth == fileInfo.bitDepth
            && ratesMatch(samplingRate, fileInfo.samplingRate)
    }

    public var reuseKey: String {
        Self.reuseKey(
            trackID: qobuzTrackID,
            albumID: qobuzAlbumID,
            formatID: formatID,
            bitDepth: bitDepth,
            samplingRate: samplingRate
        )
    }

    public static func reuseKey(item: QobuzResolvedTrack, fileInfo: QobuzFileInfo) -> String {
        reuseKey(
            trackID: item.track.id.rawValue,
            albumID: item.album.id.rawValue,
            formatID: fileInfo.formatID,
            bitDepth: fileInfo.bitDepth,
            samplingRate: fileInfo.samplingRate
        )
    }

    func markingLibraryManaged() -> QobuzFileProvenance {
        QobuzFileProvenance(
            qobuzTrackID: qobuzTrackID,
            qobuzAlbumID: qobuzAlbumID,
            formatID: formatID,
            bitDepth: bitDepth,
            samplingRate: samplingRate,
            sha256: sha256,
            archiveKind: archiveKind,
            isLibraryManaged: true
        )
    }

    private static func reuseKey(
        trackID: String,
        albumID: String,
        formatID: Int,
        bitDepth: Int?,
        samplingRate: Double?
    ) -> String {
        let depth = bitDepth.map { String($0) } ?? "-"
        let rate = samplingRate.map { String($0) } ?? "-"
        return "\(trackID)|\(albumID)|\(formatID)|\(depth)|\(rate)"
    }

    private func ratesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) < 0.001
        default: false
        }
    }

    private init(
        qobuzTrackID: String,
        qobuzAlbumID: String,
        formatID: Int,
        bitDepth: Int?,
        samplingRate: Double?,
        sha256: String,
        archiveKind: QobuzArchiveKind,
        isLibraryManaged: Bool
    ) {
        self.qobuzTrackID = qobuzTrackID
        self.qobuzAlbumID = qobuzAlbumID
        self.formatID = formatID
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.sha256 = sha256
        self.archiveKind = archiveKind
        self.isLibraryManaged = isLibraryManaged
    }
}
