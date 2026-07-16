import Foundation

public struct QobuzAlbumSummary: Codable, Equatable, Sendable {
    public let id: QobuzID
    public let title: String
    public let version: String?
    public let artist: QobuzArtist?
    public let artists: [QobuzArtistCredit]
    public let image: QobuzImage?
    public let subtitle: String?
    public let releaseDate: String?
    public let genre: String?
    public let genresList: [String]
    public let releaseType: QobuzReleaseType?
    public let releaseTags: [String]
    public let isOfficial: Bool?
    public let awards: [QobuzEditorialAward]
    public let streamable: Bool?
    public let downloadable: Bool?
    public let displayable: Bool?
    public let purchasable: Bool?
    public let maximumSamplingRate: Double?
    public let maximumBitDepth: Int?
    public let maximumChannelCount: Int?
    public let hiresStreamable: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, version, subtitle, artist, artists, image, genre, awards
        case streamable, downloadable, displayable, purchasable
        case releaseDate = "release_date_original"
        case genresList = "genres_list"
        case releaseType = "release_type"
        case releaseTags = "release_tags"
        case isOfficial = "is_official"
        case maximumSamplingRate = "maximum_sampling_rate"
        case maximumBitDepth = "maximum_bit_depth"
        case maximumChannelCount = "maximum_channel_count"
        case hiresStreamable = "hires_streamable"
    }

    private struct NamedValue: Codable { let name: String }

    public init(
        id: QobuzID,
        title: String,
        version: String? = nil,
        artist: QobuzArtist? = nil,
        artists: [QobuzArtistCredit] = [],
        image: QobuzImage? = nil,
        streamable: Bool? = true,
        downloadable: Bool? = true,
        displayable: Bool? = true,
        purchasable: Bool? = nil,
        maximumSamplingRate: Double? = nil,
        maximumBitDepth: Int? = nil,
        hiresStreamable: Bool = false,
        maximumChannelCount: Int? = nil,
        subtitle: String? = nil,
        releaseDate: String? = nil,
        genre: String? = nil,
        genresList: [String] = [],
        releaseType: QobuzReleaseType? = nil,
        releaseTags: [String] = [],
        isOfficial: Bool? = nil,
        awards: [QobuzEditorialAward] = []
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.artist = artist
        self.artists = artists
        self.image = image
        self.subtitle = subtitle
        self.releaseDate = releaseDate
        self.genre = genre
        self.genresList = genresList
        self.releaseType = releaseType
        self.releaseTags = releaseTags
        self.isOfficial = isOfficial
        self.awards = awards
        self.streamable = streamable
        self.downloadable = downloadable
        self.displayable = displayable
        self.purchasable = purchasable
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumBitDepth = maximumBitDepth
        self.maximumChannelCount = maximumChannelCount
        self.hiresStreamable = hiresStreamable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        version = container.qobuzTolerant(String.self, forKey: .version)
        artist = container.qobuzTolerant(QobuzArtist.self, forKey: .artist)
        artists = container.qobuzTolerantArray(QobuzArtistCredit.self, forKey: .artists)
        image = container.qobuzTolerant(QobuzImage.self, forKey: .image)
        subtitle = container.qobuzTolerant(String.self, forKey: .subtitle)
        releaseDate = container.qobuzTolerant(String.self, forKey: .releaseDate)
        genre = container.qobuzTolerant(NamedValue.self, forKey: .genre)?.name
        genresList = container.qobuzTolerantArray(String.self, forKey: .genresList)
        releaseType = container.qobuzTolerant(QobuzReleaseType.self, forKey: .releaseType)
        releaseTags = container.qobuzTolerantArray(String.self, forKey: .releaseTags)
        isOfficial = container.qobuzAvailabilityFlag(forKey: .isOfficial)
        awards = container.qobuzTolerantArray(QobuzEditorialAward.self, forKey: .awards)
        streamable = container.qobuzAvailabilityFlag(forKey: .streamable)
        downloadable = container.qobuzAvailabilityFlag(forKey: .downloadable)
        displayable = container.qobuzAvailabilityFlag(forKey: .displayable)
        purchasable = container.qobuzAvailabilityFlag(forKey: .purchasable)
        maximumSamplingRate = container.qobuzTolerant(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = container.qobuzTolerant(Int.self, forKey: .maximumBitDepth)
        maximumChannelCount = container.qobuzTolerant(Int.self, forKey: .maximumChannelCount)
        hiresStreamable = container.qobuzAvailabilityFlag(forKey: .hiresStreamable) ?? false
    }
}
