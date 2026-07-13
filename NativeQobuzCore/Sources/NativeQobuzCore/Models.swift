import Foundation

public struct QobuzID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            rawValue = value
        } else if let value = try? container.decode(Int64.self) {
            rawValue = String(value)
        } else {
            throw DecodingError.typeMismatch(
                QobuzID.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer Qobuz ID")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct QobuzCredentials: Equatable, Sendable {
    /// Qobuz application identifier sent only as the API's `app_id`.
    /// This is deliberately not a Qobuz account user ID.
    public let appID: String
    public let appSecret: String
    public let authToken: String

    public init(appID: String, appSecret: String, authToken: String) {
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool {
        !appID.isEmpty && !appSecret.isEmpty && !authToken.isEmpty
    }
}

public enum QobuzQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case mp3 = "high"
    case lossless
    case hiRes = "hifi"

    public var formatID: Int {
        switch self {
        case .mp3: 5
        case .lossless: 6
        case .hiRes: 27
        }
    }

    public init?(formatID: Int) {
        guard let quality = Self.allCases.first(where: { $0.formatID == formatID }) else {
            return nil
        }
        self = quality
    }
}

public enum QobuzRequest: Codable, Equatable, Sendable {
    case track(QobuzID)
    case album(QobuzID)
    case playlist(QobuzID)
    case artist(QobuzID)
    case label(QobuzID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case track
        case album
        case playlist
        case artist
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(QobuzID.self, forKey: .id)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .track: self = .track(id)
        case .album: self = .album(id)
        case .playlist: self = .playlist(id)
        case .artist: self = .artist(id)
        case .label: self = .label(id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        let kind: Kind = switch self {
        case .track: .track
        case .album: .album
        case .playlist: .playlist
        case .artist: .artist
        case .label: .label
        }
        try container.encode(kind, forKey: .kind)
    }
}

public extension QobuzRequest {
    var id: QobuzID {
        switch self {
        case .track(let id), .album(let id), .playlist(let id), .artist(let id), .label(let id): id
        }
    }

    var kindName: String {
        switch self {
        case .track: "Track"
        case .album: "Album"
        case .playlist: "Playlist"
        case .artist: "Artist"
        case .label: "Label"
        }
    }

    var canonicalURL: URL {
        let kind = kindName.lowercased()
        return URL(string: "https://open.qobuz.com/\(kind)/\(id.rawValue)")!
    }
}

public enum QobuzSearchCategory: String, CaseIterable, Hashable, Sendable {
    case albums
    case artists
    case playlists
    case tracks
}

public struct QobuzSearchResults: Equatable, Sendable {
    public let albums: [QobuzAlbumSummary]
    public let artists: [QobuzArtist]
    public let playlists: [QobuzPlaylist]
    public let tracks: [QobuzTrack]
    /// Raw Qobuz result offset consumed by this page.
    public let offset: Int
    /// Offset for the next raw Qobuz page, or `nil` when the category is exhausted.
    public let nextOffset: Int?
    /// Total result count reported by Qobuz before account-availability filtering.
    public let total: Int?

    public init(
        albums: [QobuzAlbumSummary] = [],
        artists: [QobuzArtist] = [],
        playlists: [QobuzPlaylist] = [],
        tracks: [QobuzTrack] = [],
        offset: Int = 0,
        nextOffset: Int? = nil,
        total: Int? = nil
    ) {
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.tracks = tracks
        self.offset = offset
        self.nextOffset = nextOffset
        self.total = total
    }
}

public struct QobuzArtist: Codable, Equatable, Sendable {
    public let id: QobuzID?
    public let name: String
    public let image: QobuzImage?

    public init(id: QobuzID?, name: String, image: QobuzImage? = nil) {
        self.id = id
        self.name = name
        self.image = image
    }
}

public struct QobuzArtistCredit: Codable, Equatable, Sendable {
    public let id: QobuzID?
    public let name: String
    public let roles: [String]

    public init(id: QobuzID? = nil, name: String, roles: [String] = []) {
        self.id = id
        self.name = name
        self.roles = roles
    }

    private enum CodingKeys: String, CodingKey { case id, name, roles }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(QobuzID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        roles = try container.decodeIfPresent([String].self, forKey: .roles) ?? []
    }

    public var isMainArtist: Bool {
        roles.isEmpty || roles.contains {
            let value = $0.folding(options: [.diacriticInsensitive], locale: .current)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            return value == "main-artist" || value == "mainartist"
        }
    }
}

public struct QobuzLabelSummary: Codable, Equatable, Sendable {
    public let id: QobuzID?
    public let name: String
    public let slug: String?
    public let albumsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case albumsCount = "albums_count"
    }

    public init(id: QobuzID? = nil, name: String, slug: String? = nil, albumsCount: Int? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.albumsCount = albumsCount
    }
}

public struct QobuzImage: Codable, Equatable, Sendable {
    public let large: URL?
    public let small: URL?
    public let thumbnail: URL?

    public init(large: URL? = nil, small: URL? = nil, thumbnail: URL? = nil) {
        self.large = large
        self.small = small
        self.thumbnail = thumbnail
    }

    public var bestURL: URL? { large ?? small ?? thumbnail }
}

public struct QobuzAlbumSummary: Codable, Equatable, Sendable {
    public let id: QobuzID
    public let title: String
    public let version: String?
    public let artist: QobuzArtist?
    public let artists: [QobuzArtistCredit]
    public let image: QobuzImage?
    public let streamable: Bool
    public let downloadable: Bool
    public let displayable: Bool
    public let purchasable: Bool?
    public let maximumSamplingRate: Double?
    public let maximumBitDepth: Int?
    public let hiresStreamable: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, version, artist, artists, image, streamable, downloadable, displayable, purchasable
        case maximumSamplingRate = "maximum_sampling_rate"
        case maximumBitDepth = "maximum_bit_depth"
        case hiresStreamable = "hires_streamable"
    }

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
        hiresStreamable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.artist = artist
        self.artists = artists
        self.image = image
        self.streamable = streamable
        self.downloadable = downloadable
        self.displayable = displayable
        self.purchasable = purchasable
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumBitDepth = maximumBitDepth
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
        streamable = try container.decodeIfPresent(Bool.self, forKey: .streamable) ?? false
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable) ?? false
        displayable = try container.decodeIfPresent(Bool.self, forKey: .displayable) ?? false
        purchasable = try container.decodeIfPresent(Bool.self, forKey: .purchasable)
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
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
    public let parentalWarning: Bool
    public let streamable: Bool
    public let downloadable: Bool
    public let purchasable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, version, performer, composer, album, duration, isrc, work, performers
        case trackNumber = "track_number"
        case mediaNumber = "media_number"
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
        purchasable: Bool? = nil
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
    public let artist: QobuzArtist
    public let artists: [QobuzArtistCredit]
    public let image: QobuzImage?
    public let tracks: [QobuzTrack]
    public let tracksCount: Int?
    public let mediaCount: Int?
    public let duration: Int?
    public let releaseDate: String?
    public let genre: String?
    public let label: String?
    public let labelInfo: QobuzLabelSummary?
    public let albumDescription: String?
    public let copyright: String?
    public let upc: String?
    public let parentalWarning: Bool
    public let maximumSamplingRate: Double?
    public let maximumBitDepth: Int?
    public let hiresStreamable: Bool
    public let bookletURL: URL?
    public let streamable: Bool
    public let downloadable: Bool
    public let displayable: Bool
    public let purchasable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, version, artist, artists, image, tracks, duration, upc, copyright, goodies, description
        case streamable, downloadable, displayable, purchasable
        case tracksCount = "tracks_count"
        case mediaCount = "media_count"
        case releaseDate = "release_date_original"
        case parentalWarning = "parental_warning"
        case maximumSamplingRate = "maximum_sampling_rate"
        case maximumBitDepth = "maximum_bit_depth"
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
        artist: QobuzArtist,
        artists: [QobuzArtistCredit] = [],
        image: QobuzImage? = nil,
        tracks: [QobuzTrack] = [],
        tracksCount: Int? = nil,
        mediaCount: Int? = nil,
        duration: Int? = nil,
        releaseDate: String? = nil,
        genre: String? = nil,
        label: String? = nil,
        labelInfo: QobuzLabelSummary? = nil,
        albumDescription: String? = nil,
        copyright: String? = nil,
        upc: String? = nil,
        parentalWarning: Bool = false,
        maximumSamplingRate: Double? = nil,
        maximumBitDepth: Int? = nil,
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
        self.artist = artist
        self.artists = artists
        self.image = image
        self.tracks = tracks
        self.tracksCount = tracksCount
        self.mediaCount = mediaCount
        self.duration = duration
        self.releaseDate = releaseDate
        self.genre = genre
        self.label = label ?? labelInfo?.name
        self.labelInfo = labelInfo
        self.albumDescription = albumDescription
        self.copyright = copyright
        self.upc = upc
        self.parentalWarning = parentalWarning
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumBitDepth = maximumBitDepth
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
        labelInfo = try container.decodeIfPresent(QobuzLabelSummary.self, forKey: .label)
        label = labelInfo?.name
        albumDescription = try container.decodeIfPresent(String.self, forKey: .description)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        upc = try container.decodeIfPresent(String.self, forKey: .upc)
        parentalWarning = try container.decodeIfPresent(Bool.self, forKey: .parentalWarning) ?? false
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
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

    public var mainArtists: [QobuzArtistCredit] {
        let values = artists.filter(\.isMainArtist)
        if !values.isEmpty { return values }
        return [QobuzArtistCredit(id: artist.id, name: artist.name)]
    }
}

public struct QobuzPlaylist: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let name: String
    public let tracks: [QobuzTrack]
    public let owner: QobuzPlaylistOwner?
    public let createdAt: Int?
    public let updatedAt: Int?
    public let duration: Int?
    public let playlistDescription: String?
    public let tracksCount: Int?
    public let artworkURLs: [URL]
    public let tracksTotal: Int?
    public let tracksOffset: Int?
    public let tracksLimit: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, title, tracks, owner, duration, description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case tracksCount = "tracks_count"
        case imageRectangle = "image_rectangle"
        case imageRectangleMini = "image_rectangle_mini"
    }
    private struct TracksContainer: Codable {
        let items: [QobuzTrack]
        let total: Int?
        let offset: Int?
        let limit: Int?
    }

    public init(
        id: QobuzID,
        name: String,
        tracks: [QobuzTrack],
        owner: QobuzPlaylistOwner? = nil,
        createdAt: Int? = nil,
        updatedAt: Int? = nil,
        duration: Int? = nil,
        description: String? = nil,
        tracksCount: Int? = nil,
        artworkURLs: [URL] = [],
        tracksTotal: Int? = nil,
        tracksOffset: Int? = nil,
        tracksLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.owner = owner
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.playlistDescription = description
        self.tracksCount = tracksCount
        self.artworkURLs = artworkURLs
        self.tracksTotal = tracksTotal
        self.tracksOffset = tracksOffset
        self.tracksLimit = tracksLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .title)
        let page = try container.decodeIfPresent(TracksContainer.self, forKey: .tracks)
        tracks = page?.items ?? []
        owner = try container.decodeIfPresent(QobuzPlaylistOwner.self, forKey: .owner)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        playlistDescription = try container.decodeIfPresent(String.self, forKey: .description)
        tracksCount = try container.decodeIfPresent(Int.self, forKey: .tracksCount)
        artworkURLs = (
            (try container.decodeIfPresent([URL].self, forKey: .imageRectangle) ?? [])
            + (try container.decodeIfPresent([URL].self, forKey: .imageRectangleMini) ?? [])
        )
        tracksTotal = page?.total
        tracksOffset = page?.offset
        tracksLimit = page?.limit
    }

    public var artworkURL: URL? { artworkURLs.first }
}

public struct QobuzPlaylistOwner: Codable, Equatable, Sendable {
    public let id: QobuzID?
    public let name: String

    public init(id: QobuzID? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct QobuzArtistCatalog: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let name: String
    public let image: QobuzImage?
    public let albums: [QobuzAlbum]
    public let albumsTotal: Int?
    public let albumsOffset: Int?
    public let albumsLimit: Int?

    enum CodingKeys: String, CodingKey { case id, name, image, albums }
    private struct AlbumsContainer: Decodable {
        let items: [QobuzAlbum]
        let total: Int?
        let offset: Int?
        let limit: Int?
    }

    public init(
        id: QobuzID,
        name: String,
        image: QobuzImage? = nil,
        albums: [QobuzAlbum],
        albumsTotal: Int? = nil,
        albumsOffset: Int? = nil,
        albumsLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.albums = albums
        self.albumsTotal = albumsTotal
        self.albumsOffset = albumsOffset
        self.albumsLimit = albumsLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        image = try container.decodeIfPresent(QobuzImage.self, forKey: .image)
        let albumPage = try container.decodeIfPresent(AlbumsContainer.self, forKey: .albums)
        albums = albumPage?.items ?? []
        albumsTotal = albumPage?.total
        albumsOffset = albumPage?.offset
        albumsLimit = albumPage?.limit
    }
}

public struct QobuzLabelCatalog: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let name: String
    public let slug: String?
    public let albums: [QobuzAlbum]
    public let albumsTotal: Int?
    public let albumsOffset: Int?
    public let albumsLimit: Int?

    enum CodingKeys: String, CodingKey { case id, name, slug, albums }
    private struct AlbumsContainer: Decodable {
        let items: [QobuzAlbum]
        let total: Int?
        let offset: Int?
        let limit: Int?
    }

    public init(
        id: QobuzID,
        name: String,
        slug: String? = nil,
        albums: [QobuzAlbum],
        albumsTotal: Int? = nil,
        albumsOffset: Int? = nil,
        albumsLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.albums = albums
        self.albumsTotal = albumsTotal
        self.albumsOffset = albumsOffset
        self.albumsLimit = albumsLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        let page = try container.decodeIfPresent(AlbumsContainer.self, forKey: .albums)
        albums = page?.items ?? []
        albumsTotal = page?.total
        albumsOffset = page?.offset
        albumsLimit = page?.limit
    }

    public var availableAlbums: [QobuzAlbum] {
        albums.filter { $0.accountAvailabilityIssue == nil }
    }
}

public enum QobuzArtistReleaseRelationship: Equatable, Sendable {
    case official
    case appearance
}

public enum QobuzAvailabilityIssue: Equatable, Sendable {
    case notDisplayable
    case notStreamable
    case notPurchasable
}

public extension QobuzAlbumSummary {
    var mainArtists: [QobuzArtistCredit] {
        let values = artists.filter(\.isMainArtist)
        if !values.isEmpty { return values }
        return artist.map { [QobuzArtistCredit(id: $0.id, name: $0.name)] } ?? []
    }

    var albumArtistDisplayName: String {
        let value = mainArtists.map(\.name).joined(separator: ", ")
        return value.isEmpty ? (artist?.name ?? "Unknown Artist") : value
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        if !displayable { return .notDisplayable }
        if !streamable { return .notStreamable }
        if purchasable == false { return .notPurchasable }
        return nil
    }
}

public extension QobuzTrack {
    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        if !streamable { return .notStreamable }
        if purchasable == false { return .notPurchasable }
        return nil
    }
}

public extension QobuzAlbum {
    var albumArtistDisplayName: String {
        mainArtists.map(\.name).joined(separator: ", ")
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        if !displayable { return .notDisplayable }
        if !streamable { return .notStreamable }
        if purchasable == false { return .notPurchasable }
        return nil
    }

    var availableTracks: [QobuzTrack] {
        tracks.filter { $0.accountAvailabilityIssue == nil }
    }

    var unavailableTrackCount: Int {
        tracks.count - availableTracks.count
    }
}

public extension QobuzPlaylist {
    var availableTracks: [QobuzTrack] {
        tracks.filter { $0.accountAvailabilityIssue == nil }
    }

    var unavailableTrackCount: Int {
        tracks.count - availableTracks.count
    }
}

public extension QobuzArtistCatalog {
    var availableAlbums: [QobuzAlbum] {
        albums.filter { $0.accountAvailabilityIssue == nil }
    }

    var allOfficialAlbums: [QobuzAlbum] {
        albums.filter { relationship(of: $0) == .official }
    }

    var officialAlbums: [QobuzAlbum] {
        allOfficialAlbums.filter { $0.accountAvailabilityIssue == nil }
    }

    var appearanceAlbums: [QobuzAlbum] {
        availableAlbums.filter { relationship(of: $0) == .appearance }
    }

    func relationship(of album: QobuzAlbum) -> QobuzArtistReleaseRelationship {
        if album.mainArtists.contains(where: { $0.id == id }) {
            return .official
        }
        if let albumArtistID = album.artist.id {
            return albumArtistID == id ? .official : .appearance
        }
        return normalizedArtistName(album.artist.name) == normalizedArtistName(name)
            ? .official
            : .appearance
    }

    private func normalizedArtistName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

public struct QobuzFileInfo: Codable, Equatable, Sendable {
    public let url: URL
    public let formatID: Int
    public let bitDepth: Int?
    public let samplingRate: Double?

    enum CodingKeys: String, CodingKey {
        case url
        case formatID = "format_id"
        case bitDepth = "bit_depth"
        case samplingRate = "sampling_rate"
    }

    public init(url: URL, formatID: Int, bitDepth: Int? = nil, samplingRate: Double? = nil) {
        self.url = url
        self.formatID = formatID
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
    }

    public var fileExtension: String { formatID == 5 ? "mp3" : "flac" }
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
}

public enum NativeQobuzError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidCredentials
    case freeAccount
    case unavailable(String)
    case invalidResponse(String)
    case http(Int, String)
    case network(String)
    case emptyCollection(String)
    case missingAlbum(QobuzID)
    case cancelled
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "Qobuz credentials are incomplete."
        case .invalidCredentials: "Qobuz credentials are invalid or expired."
        case .freeAccount: "This Qobuz account is not eligible for downloading."
        case .unavailable(let message): message
        case .invalidResponse(let message): "Invalid Qobuz response: \(message)"
        case .http(let status, let message): "Qobuz returned HTTP \(status): \(message)"
        case .network(let message): "Could not reach Qobuz: \(message)"
        case .emptyCollection(let name): "Qobuz returned no downloadable tracks for \(name)."
        case .missingAlbum(let id): "Track metadata is missing album \(id.rawValue)."
        case .cancelled: "Download cancelled."
        case .fileSystem(let message): "File operation failed: \(message)"
        }
    }

    public var canResumeTransfer: Bool {
        switch self {
        case .network:
            true
        case .http(let status, _):
            status == 403 || status == 408 || status == 409 || status == 416
                || status == 425 || status == 429 || (500...599).contains(status)
        default:
            false
        }
    }
}
