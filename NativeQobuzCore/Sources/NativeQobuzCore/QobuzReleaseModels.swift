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
    public let streamable: Bool
    public let downloadable: Bool
    public let displayable: Bool
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
        streamable: Bool = true,
        downloadable: Bool = true,
        displayable: Bool = true,
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
        version = try container.decodeIfPresent(String.self, forKey: .version)
        artist = try container.decodeIfPresent(QobuzArtist.self, forKey: .artist)
        artists = try container.decodeIfPresent([QobuzArtistCredit].self, forKey: .artists) ?? []
        image = try container.decodeIfPresent(QobuzImage.self, forKey: .image)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        genre = try container.decodeIfPresent(NamedValue.self, forKey: .genre)?.name
        genresList = try container.decodeIfPresent([String].self, forKey: .genresList) ?? []
        releaseType = try container.decodeIfPresent(QobuzReleaseType.self, forKey: .releaseType)
        releaseTags = try container.decodeIfPresent([String].self, forKey: .releaseTags) ?? []
        isOfficial = try container.decodeIfPresent(Bool.self, forKey: .isOfficial)
        awards = try container.decodeIfPresent([QobuzEditorialAward].self, forKey: .awards) ?? []
        streamable = try container.decodeIfPresent(Bool.self, forKey: .streamable) ?? false
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable) ?? false
        displayable = try container.decodeIfPresent(Bool.self, forKey: .displayable) ?? false
        purchasable = try container.decodeIfPresent(Bool.self, forKey: .purchasable)
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
        maximumChannelCount = try container.decodeIfPresent(Int.self, forKey: .maximumChannelCount)
        hiresStreamable = try container.decodeIfPresent(Bool.self, forKey: .hiresStreamable) ?? false
    }
}
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
    public let streamable: Bool
    public let downloadable: Bool
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
        streamable: Bool = true,
        downloadable: Bool = true,
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
        version = try container.decodeIfPresent(String.self, forKey: .version)
        performer = try container.decodeIfPresent(QobuzArtist.self, forKey: .performer)
        composer = try container.decodeIfPresent(QobuzArtist.self, forKey: .composer)
        album = try container.decodeIfPresent(QobuzAlbumSummary.self, forKey: .album)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        mediaNumber = try container.decodeIfPresent(Int.self, forKey: .mediaNumber)
        isrc = try container.decodeIfPresent(String.self, forKey: .isrc)
        work = try container.decodeIfPresent(String.self, forKey: .work)
        performers = try container.decodeIfPresent(String.self, forKey: .performers)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
        maximumChannelCount = try container.decodeIfPresent(Int.self, forKey: .maximumChannelCount)
        parentalWarning = try container.decodeIfPresent(Bool.self, forKey: .parentalWarning) ?? false
        streamable = try container.decodeIfPresent(Bool.self, forKey: .streamable) ?? false
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable) ?? false
        purchasable = try container.decodeIfPresent(Bool.self, forKey: .purchasable)
    }
}

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
    public let streamable: Bool
    public let downloadable: Bool
    public let displayable: Bool
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
    private struct TracksContainer: Codable { let items: [QobuzTrack] }
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
        streamable: Bool = true,
        downloadable: Bool = true,
        displayable: Bool = true,
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
        version = try container.decodeIfPresent(String.self, forKey: .version)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        artist = try container.decodeIfPresent(QobuzArtist.self, forKey: .artist)
            ?? QobuzArtist(id: nil, name: "Unknown Artist")
        artists = try container.decodeIfPresent([QobuzArtistCredit].self, forKey: .artists) ?? []
        image = try container.decodeIfPresent(QobuzImage.self, forKey: .image)
        tracks = try container.decodeIfPresent(TracksContainer.self, forKey: .tracks)?.items ?? []
        tracksCount = try container.decodeIfPresent(Int.self, forKey: .tracksCount)
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        genre = try container.decodeIfPresent(NamedValue.self, forKey: .genre)?.name
        genresList = try container.decodeIfPresent([String].self, forKey: .genresList) ?? []
        releaseType = try container.decodeIfPresent(QobuzReleaseType.self, forKey: .releaseType)
        releaseTags = try container.decodeIfPresent([String].self, forKey: .releaseTags) ?? []
        isOfficial = try container.decodeIfPresent(Bool.self, forKey: .isOfficial)
        labelInfo = try container.decodeIfPresent(QobuzLabelSummary.self, forKey: .label)
        label = labelInfo?.name
        albumDescription = try container.decodeIfPresent(String.self, forKey: .description)
        catchline = try container.decodeIfPresent(String.self, forKey: .catchline)
        awards = try container.decodeIfPresent([QobuzEditorialAward].self, forKey: .awards) ?? []
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        upc = try container.decodeIfPresent(String.self, forKey: .upc)
        parentalWarning = try container.decodeIfPresent(Bool.self, forKey: .parentalWarning) ?? false
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
        maximumChannelCount = try container.decodeIfPresent(Int.self, forKey: .maximumChannelCount)
        hiresStreamable = try container.decodeIfPresent(Bool.self, forKey: .hiresStreamable) ?? false
        bookletURL = try container.decodeIfPresent([Goodie].self, forKey: .goodies)?.first?.url
        streamable = try container.decodeIfPresent(Bool.self, forKey: .streamable) ?? true
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable) ?? true
        displayable = try container.decodeIfPresent(Bool.self, forKey: .displayable) ?? true
        purchasable = try container.decodeIfPresent(Bool.self, forKey: .purchasable)
    }

    public var displayTitle: String {
        guard let version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }

}
