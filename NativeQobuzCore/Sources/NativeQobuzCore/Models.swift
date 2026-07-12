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

public enum QobuzQuality: String, Codable, CaseIterable, Sendable {
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
}

public enum QobuzRequest: Equatable, Sendable {
    case track(QobuzID)
    case album(QobuzID)
    case playlist(QobuzID)
    case artist(QobuzID)
}

public extension QobuzRequest {
    var id: QobuzID {
        switch self {
        case .track(let id), .album(let id), .playlist(let id), .artist(let id): id
        }
    }

    var kindName: String {
        switch self {
        case .track: "Track"
        case .album: "Album"
        case .playlist: "Playlist"
        case .artist: "Artist"
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
    case tracks
}

public struct QobuzSearchResults: Equatable, Sendable {
    public let albums: [QobuzAlbumSummary]
    public let artists: [QobuzArtist]
    public let tracks: [QobuzTrack]

    public init(
        albums: [QobuzAlbumSummary] = [],
        artists: [QobuzArtist] = [],
        tracks: [QobuzTrack] = []
    ) {
        self.albums = albums
        self.artists = artists
        self.tracks = tracks
    }
}

public struct QobuzArtist: Codable, Equatable, Sendable {
    public let id: QobuzID?
    public let name: String

    public init(id: QobuzID?, name: String) {
        self.id = id
        self.name = name
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
    public let image: QobuzImage?

    public init(
        id: QobuzID,
        title: String,
        version: String? = nil,
        artist: QobuzArtist? = nil,
        image: QobuzImage? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.artist = artist
        self.image = image
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

    enum CodingKeys: String, CodingKey {
        case id, title, version, performer, composer, album, duration, isrc, work, performers
        case trackNumber = "track_number"
        case mediaNumber = "media_number"
        case parentalWarning = "parental_warning"
        case streamable, downloadable
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
        downloadable: Bool = true
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
        streamable = try container.decodeIfPresent(Bool.self, forKey: .streamable) ?? true
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable) ?? true
    }
}

public struct QobuzAlbum: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let title: String
    public let version: String?
    public let artist: QobuzArtist
    public let image: QobuzImage?
    public let tracks: [QobuzTrack]
    public let tracksCount: Int?
    public let mediaCount: Int?
    public let duration: Int?
    public let releaseDate: String?
    public let genre: String?
    public let label: String?
    public let copyright: String?
    public let upc: String?
    public let parentalWarning: Bool
    public let maximumSamplingRate: Double?
    public let maximumBitDepth: Int?
    public let hiresStreamable: Bool
    public let bookletURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, version, artist, image, tracks, duration, upc, copyright, goodies
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
        image: QobuzImage? = nil,
        tracks: [QobuzTrack] = [],
        tracksCount: Int? = nil,
        mediaCount: Int? = nil,
        duration: Int? = nil,
        releaseDate: String? = nil,
        genre: String? = nil,
        label: String? = nil,
        copyright: String? = nil,
        upc: String? = nil,
        parentalWarning: Bool = false,
        maximumSamplingRate: Double? = nil,
        maximumBitDepth: Int? = nil,
        hiresStreamable: Bool = false,
        bookletURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.artist = artist
        self.image = image
        self.tracks = tracks
        self.tracksCount = tracksCount
        self.mediaCount = mediaCount
        self.duration = duration
        self.releaseDate = releaseDate
        self.genre = genre
        self.label = label
        self.copyright = copyright
        self.upc = upc
        self.parentalWarning = parentalWarning
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumBitDepth = maximumBitDepth
        self.hiresStreamable = hiresStreamable
        self.bookletURL = bookletURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        artist = try container.decodeIfPresent(QobuzArtist.self, forKey: .artist)
            ?? QobuzArtist(id: nil, name: "Unknown Artist")
        image = try container.decodeIfPresent(QobuzImage.self, forKey: .image)
        tracks = try container.decodeIfPresent(TracksContainer.self, forKey: .tracks)?.items ?? []
        tracksCount = try container.decodeIfPresent(Int.self, forKey: .tracksCount)
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        genre = try container.decodeIfPresent(NamedValue.self, forKey: .genre)?.name
        label = try container.decodeIfPresent(NamedValue.self, forKey: .label)?.name
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        upc = try container.decodeIfPresent(String.self, forKey: .upc)
        parentalWarning = try container.decodeIfPresent(Bool.self, forKey: .parentalWarning) ?? false
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
        hiresStreamable = try container.decodeIfPresent(Bool.self, forKey: .hiresStreamable) ?? false
        bookletURL = try container.decodeIfPresent([Goodie].self, forKey: .goodies)?.first?.url
    }

    public var displayTitle: String {
        guard let version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }
}

public struct QobuzPlaylist: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let name: String
    public let tracks: [QobuzTrack]

    enum CodingKeys: String, CodingKey { case id, name, title, tracks }
    private struct TracksContainer: Codable { let items: [QobuzTrack] }

    public init(id: QobuzID, name: String, tracks: [QobuzTrack]) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .title)
        tracks = try container.decodeIfPresent(TracksContainer.self, forKey: .tracks)?.items ?? []
    }
}

public struct QobuzArtistCatalog: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let name: String
    public let albums: [QobuzAlbum]

    enum CodingKeys: String, CodingKey { case id, name, albums }
    private struct AlbumsContainer: Decodable { let items: [QobuzAlbum] }

    public init(id: QobuzID, name: String, albums: [QobuzAlbum]) {
        self.id = id
        self.name = name
        self.albums = albums
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(QobuzID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        albums = try container.decodeIfPresent(AlbumsContainer.self, forKey: .albums)?.items ?? []
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

    public init(request: QobuzRequest, title: String, tracks: [QobuzResolvedTrack]) {
        self.request = request
        self.title = title
        self.tracks = tracks
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
}
