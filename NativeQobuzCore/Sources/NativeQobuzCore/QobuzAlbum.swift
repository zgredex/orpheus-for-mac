import Foundation

public struct QobuzAlbum: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let title: String
    public let version: String?
    public let subtitle: String?
    public let artist: QobuzArtist
    public let artists: [QobuzArtistCredit]
    public let image: QobuzImage?
    public let tracks: [QobuzTrack]
    public let tracksCount: Int?
    public let mediaCount: Int?
    public let duration: Int?
    public let releaseDate: String?
    public let genre: String?
    public let genresList: [String]
    public let releaseType: QobuzReleaseType?
    public let releaseTags: [String]
    public let isOfficial: Bool?
    public let label: String?
    public let labelInfo: QobuzLabelSummary?
    public let albumDescription: String?
    public let catchline: String?
    public let awards: [QobuzEditorialAward]
    public let copyright: String?
    public let upc: String?
    public let parentalWarning: Bool
    public let maximumSamplingRate: Double?
    public let maximumBitDepth: Int?
    public let maximumChannelCount: Int?
    public let hiresStreamable: Bool
    public let bookletURL: URL?
    public let streamable: Bool?
    public let downloadable: Bool?
    public let displayable: Bool?
    public let purchasable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, version, subtitle, artist, artists, image, tracks, duration, upc, copyright
        case goodies, description, catchline, awards
        case streamable, downloadable, displayable, purchasable
        case tracksCount = "tracks_count"
        case mediaCount = "media_count"
        case releaseDate = "release_date_original"
        case genresList = "genres_list"
        case releaseType = "release_type"
        case releaseTags = "release_tags"
        case isOfficial = "is_official"
        case parentalWarning = "parental_warning"
        case maximumSamplingRate = "maximum_sampling_rate"
        case maximumBitDepth = "maximum_bit_depth"
        case maximumChannelCount = "maximum_channel_count"
        case hiresStreamable = "hires_streamable"
        case genre, label
    }

    private struct NamedValue: Codable { let name: String }
    private typealias TracksContainer = QobuzStrictPage<QobuzTrack>
    private struct Goodie: Codable { let url: URL }

    public init(
        id: QobuzID,
        title: String,
        version: String? = nil,
        subtitle: String? = nil,
        artist: QobuzArtist,
        artists: [QobuzArtistCredit] = [],
        image: QobuzImage? = nil,
        tracks: [QobuzTrack] = [],
        tracksCount: Int? = nil,
        mediaCount: Int? = nil,
        duration: Int? = nil,
        releaseDate: String? = nil,
        genre: String? = nil,
        genresList: [String] = [],
        releaseType: QobuzReleaseType? = nil,
        releaseTags: [String] = [],
        isOfficial: Bool? = nil,
        label: String? = nil,
        labelInfo: QobuzLabelSummary? = nil,
        albumDescription: String? = nil,
        catchline: String? = nil,
        awards: [QobuzEditorialAward] = [],
        copyright: String? = nil,
        upc: String? = nil,
        parentalWarning: Bool = false,
        maximumSamplingRate: Double? = nil,
        maximumBitDepth: Int? = nil,
        maximumChannelCount: Int? = nil,
        hiresStreamable: Bool = false,
        bookletURL: URL? = nil,
        streamable: Bool? = true,
        downloadable: Bool? = true,
        displayable: Bool? = true,
        purchasable: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.subtitle = subtitle
        self.artist = artist
        self.artists = artists
        self.image = image
        self.tracks = tracks
        self.tracksCount = tracksCount
        self.mediaCount = mediaCount
        self.duration = duration
        self.releaseDate = releaseDate
        self.genre = genre
        self.genresList = genresList
        self.releaseType = releaseType
        self.releaseTags = releaseTags
        self.isOfficial = isOfficial
        self.label = label ?? labelInfo?.name
        self.labelInfo = labelInfo
        self.albumDescription = albumDescription
        self.catchline = catchline
        self.awards = awards
        self.copyright = copyright
        self.upc = upc
        self.parentalWarning = parentalWarning
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumBitDepth = maximumBitDepth
        self.maximumChannelCount = maximumChannelCount
        self.hiresStreamable = hiresStreamable
        self.bookletURL = bookletURL
        self.streamable = streamable
        self.downloadable = downloadable
        self.displayable = displayable
        self.purchasable = purchasable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        version = container.qobuzTolerant(String.self, forKey: .version)
        subtitle = container.qobuzTolerant(String.self, forKey: .subtitle)
        artist = container.qobuzTolerant(QobuzArtist.self, forKey: .artist)
            ?? QobuzArtist(id: nil, name: "Unknown Artist")
        artists = container.qobuzTolerantArray(QobuzArtistCredit.self, forKey: .artists)
        image = container.qobuzTolerant(QobuzImage.self, forKey: .image)
        tracks = try container.decodeIfPresent(TracksContainer.self, forKey: .tracks)?.items ?? []
        tracksCount = container.qobuzTolerant(Int.self, forKey: .tracksCount)
        mediaCount = container.qobuzTolerant(Int.self, forKey: .mediaCount)
        duration = container.qobuzTolerant(Int.self, forKey: .duration)
        releaseDate = container.qobuzTolerant(String.self, forKey: .releaseDate)
        genre = container.qobuzTolerant(NamedValue.self, forKey: .genre)?.name
            ?? container.qobuzTolerant(String.self, forKey: .genre)
        genresList = container.qobuzTolerantArray(String.self, forKey: .genresList)
        releaseType = container.qobuzTolerant(QobuzReleaseType.self, forKey: .releaseType)
        releaseTags = container.qobuzTolerantArray(String.self, forKey: .releaseTags)
        isOfficial = container.qobuzAvailabilityFlag(forKey: .isOfficial)
        labelInfo = container.qobuzTolerant(QobuzLabelSummary.self, forKey: .label)
        label = labelInfo?.name ?? container.qobuzTolerant(String.self, forKey: .label)
        albumDescription = container.qobuzTolerant(String.self, forKey: .description)
        catchline = container.qobuzTolerant(String.self, forKey: .catchline)
        awards = container.qobuzTolerantArray(QobuzEditorialAward.self, forKey: .awards)
        copyright = container.qobuzTolerant(String.self, forKey: .copyright)
        upc = container.qobuzTolerant(String.self, forKey: .upc)
        parentalWarning = container.qobuzAvailabilityFlag(forKey: .parentalWarning) ?? false
        maximumSamplingRate = container.qobuzTolerant(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = container.qobuzTolerant(Int.self, forKey: .maximumBitDepth)
        maximumChannelCount = container.qobuzTolerant(Int.self, forKey: .maximumChannelCount)
        hiresStreamable = container.qobuzAvailabilityFlag(forKey: .hiresStreamable) ?? false
        bookletURL = container.qobuzTolerantArray(Goodie.self, forKey: .goodies).first?.url
        streamable = container.qobuzAvailabilityFlag(forKey: .streamable)
        downloadable = container.qobuzAvailabilityFlag(forKey: .downloadable)
        displayable = container.qobuzAvailabilityFlag(forKey: .displayable)
        purchasable = container.qobuzAvailabilityFlag(forKey: .purchasable)
    }

    public var displayTitle: String {
        guard let version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }
}
