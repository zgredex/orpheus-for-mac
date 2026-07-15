import Foundation

public struct QobuzFileRestriction: Codable, Equatable, Sendable {
    public let code: String
    public let message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }
}
public struct QobuzFileInfo: Codable, Equatable, Sendable {
    public let url: URL
    public let format: QobuzAudioFormat
    public let bitDepth: Int?
    public let samplingRate: Double?
    public let restrictions: [QobuzFileRestriction]

    public var formatID: Int { format.formatID }

    enum CodingKeys: String, CodingKey {
        case url
        case formatID = "format_id"
        case bitDepth = "bit_depth"
        case samplingRate = "sampling_rate"
        case restrictions
    }

    public init(
        url: URL,
        format: QobuzAudioFormat,
        bitDepth: Int? = nil,
        samplingRate: Double? = nil,
        restrictions: [QobuzFileRestriction] = []
    ) {
        self.url = url
        self.format = format
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.restrictions = restrictions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        let formatID = try container.decode(Int.self, forKey: .formatID)
        guard let format = QobuzAudioFormat(formatID: formatID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatID,
                in: container,
                debugDescription: "Unsupported Qobuz audio format ID \(formatID)"
            )
        }
        self.format = format
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        samplingRate = try container.decodeIfPresent(Double.self, forKey: .samplingRate)
        restrictions = try container.decodeIfPresent([QobuzFileRestriction].self, forKey: .restrictions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(format.formatID, forKey: .formatID)
        try container.encodeIfPresent(bitDepth, forKey: .bitDepth)
        try container.encodeIfPresent(samplingRate, forKey: .samplingRate)
        if !restrictions.isEmpty {
            try container.encode(restrictions, forKey: .restrictions)
        }
    }

    public var fileExtension: String { format.fileExtension }
}

public enum QobuzCollection: Equatable, Sendable {
    case track
    case album(id: QobuzID, title: String)
    case playlist(id: QobuzID, title: String)
    case artist(id: QobuzID, name: String)
    case label(id: QobuzID, name: String)
}

public enum QobuzDownloadSource: Equatable, Sendable {
    case track(QobuzTrack)
    case album(QobuzAlbum)
    case playlist(QobuzPlaylist)
    case artist(QobuzArtistCatalog)
    case label(QobuzLabelCatalog)
}

public struct QobuzResolvedTrack: Equatable, Sendable {
    public let track: QobuzTrack
    public let album: QobuzAlbum
    public let collection: QobuzCollection
    public let position: Int
    public let total: Int

    public init(track: QobuzTrack, album: QobuzAlbum, collection: QobuzCollection, position: Int, total: Int) {
        self.track = track
        self.album = album
        self.collection = collection
        self.position = position
        self.total = total
    }
}

public struct QobuzDownloadPlan: Equatable, Sendable {
    public let request: QobuzRequest
    public let title: String
    public let tracks: [QobuzResolvedTrack]
    public let source: QobuzDownloadSource?

    public init(
        request: QobuzRequest,
        title: String,
        tracks: [QobuzResolvedTrack],
        source: QobuzDownloadSource? = nil
    ) {
        self.request = request
        self.title = title
        self.tracks = tracks
        self.source = source
    }

    /// Returns this plan restricted to the requested Qobuz track identities.
    /// Positions and totals are rebuilt so progress remains exact for a subset.
    public func selecting(trackIDs: Set<QobuzID>?) throws -> QobuzDownloadPlan {
        guard let trackIDs else { return self }
        let selected = tracks.filter { trackIDs.contains($0.track.id) }
        guard !selected.isEmpty else {
            throw NativeQobuzError.emptyCollection("the selected tracks in \(title)")
        }
        let count = selected.count
        let reindexed = selected.enumerated().map { offset, item in
            QobuzResolvedTrack(
                track: item.track,
                album: item.album,
                collection: item.collection,
                position: offset + 1,
                total: count
            )
        }
        return QobuzDownloadPlan(
            request: request,
            title: title,
            tracks: reindexed,
            source: source
        )
    }
}
