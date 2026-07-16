import Foundation

public struct QobuzTrack: Codable, Equatable, Sendable {
    public let id: QobuzID
    public let title: String
    public let version: String?
    public let performer: QobuzArtist?
    public let composer: QobuzArtist?
    public let album: QobuzAlbumSummary?
    public let duration: Int?
    public let trackNumber: Int?
    public let mediaNumber: Int?
    public let isrc: String?
    public let work: String?
    public let performers: String?
    public let copyright: String?
    public let maximumSamplingRate: Double?
    public let maximumBitDepth: Int?
    public let maximumChannelCount: Int?
    public let parentalWarning: Bool
    public let streamable: Bool?
    public let downloadable: Bool?
    public let purchasable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, version, performer, composer, album, duration, isrc, work, performers, copyright
        case trackNumber = "track_number"
        case mediaNumber = "media_number"
        case maximumSamplingRate = "maximum_sampling_rate"
        case maximumBitDepth = "maximum_bit_depth"
        case maximumChannelCount = "maximum_channel_count"
        case parentalWarning = "parental_warning"
        case streamable, downloadable, purchasable
    }

    public init(
        id: QobuzID,
        title: String,
        version: String? = nil,
        performer: QobuzArtist? = nil,
        composer: QobuzArtist? = nil,
        album: QobuzAlbumSummary? = nil,
        duration: Int? = nil,
        trackNumber: Int? = nil,
        mediaNumber: Int? = nil,
        isrc: String? = nil,
        work: String? = nil,
        performers: String? = nil,
        parentalWarning: Bool = false,
        streamable: Bool? = true,
        downloadable: Bool? = true,
        purchasable: Bool? = nil,
        copyright: String? = nil,
        maximumSamplingRate: Double? = nil,
        maximumBitDepth: Int? = nil,
        maximumChannelCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.performer = performer
        self.composer = composer
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.mediaNumber = mediaNumber
        self.isrc = isrc
        self.work = work
        self.performers = performers
        self.copyright = copyright
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumBitDepth = maximumBitDepth
        self.maximumChannelCount = maximumChannelCount
        self.parentalWarning = parentalWarning
        self.streamable = streamable
        self.downloadable = downloadable
        self.purchasable = purchasable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        version = container.qobuzTolerant(String.self, forKey: .version)
        performer = container.qobuzTolerant(QobuzArtist.self, forKey: .performer)
        composer = container.qobuzTolerant(QobuzArtist.self, forKey: .composer)
        album = container.qobuzTolerant(QobuzAlbumSummary.self, forKey: .album)
        duration = container.qobuzTolerant(Int.self, forKey: .duration)
        trackNumber = container.qobuzTolerant(Int.self, forKey: .trackNumber)
        mediaNumber = container.qobuzTolerant(Int.self, forKey: .mediaNumber)
        isrc = container.qobuzTolerant(String.self, forKey: .isrc)
        work = container.qobuzTolerant(String.self, forKey: .work)
        performers = container.qobuzTolerant(String.self, forKey: .performers)
        copyright = container.qobuzTolerant(String.self, forKey: .copyright)
        maximumSamplingRate = container.qobuzTolerant(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = container.qobuzTolerant(Int.self, forKey: .maximumBitDepth)
        maximumChannelCount = container.qobuzTolerant(Int.self, forKey: .maximumChannelCount)
        parentalWarning = container.qobuzAvailabilityFlag(forKey: .parentalWarning) ?? false
        streamable = container.qobuzAvailabilityFlag(forKey: .streamable)
        downloadable = container.qobuzAvailabilityFlag(forKey: .downloadable)
        purchasable = container.qobuzAvailabilityFlag(forKey: .purchasable)
    }
}
