import Foundation

struct FlexibleID: Codable, Hashable, CustomStringConvertible {
    let value: String

    var description: String { value }

    init(_ value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            throw DecodingError.typeMismatch(
                FlexibleID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct QobuzAlbumResponse: Codable, Equatable {
    let id: FlexibleID
    let title: String
    let version: String?
    let artist: QobuzArtist
    let image: QobuzImage?
    let genre: QobuzGenre?
    let tracks: QobuzTracksContainer?
    let duration: Int?
    let tracksCount: Int?
    let releaseDateOriginal: String?
    let parentalWarning: Bool?
    let upc: String?
    let label: QobuzLabel?
    let maximumSamplingRate: Double?
    let maximumBitDepth: Double?
    let hiresStreamable: Bool?
    let description: String?
    let goodies: [QobuzGoodie]?
    let displayable: Bool?
    let streamable: Bool?
    let downloadable: Bool?
    let qobuzID: FlexibleID?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, title, version, artist, image, genre, tracks, duration
        case tracksCount = "tracks_count"
        case releaseDateOriginal = "release_date_original"
        case parentalWarning = "parental_warning"
        case upc, label, description, goodies, displayable, streamable, downloadable, url
        case qobuzID = "qobuz_id"
        case maximumSamplingRate = "maximum_sampling_rate"
        case maximumBitDepth = "maximum_bit_depth"
        case hiresStreamable = "hires_streamable"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(FlexibleID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        artist = (try? container.decodeIfPresent(QobuzArtist.self, forKey: .artist))
            ?? QobuzArtist(id: nil, name: "Unknown Artist")
        image = try? container.decodeIfPresent(QobuzImage.self, forKey: .image)
        genre = try? container.decodeIfPresent(QobuzGenre.self, forKey: .genre)
        tracks = try? container.decodeIfPresent(QobuzTracksContainer.self, forKey: .tracks)
        duration = try? container.decodeIfPresent(Int.self, forKey: .duration)
        tracksCount = try? container.decodeIfPresent(Int.self, forKey: .tracksCount)
        releaseDateOriginal = try? container.decodeIfPresent(String.self, forKey: .releaseDateOriginal)
        parentalWarning = try? container.decodeIfPresent(Bool.self, forKey: .parentalWarning)
        upc = try? container.decodeIfPresent(String.self, forKey: .upc)
        label = try? container.decodeIfPresent(QobuzLabel.self, forKey: .label)
        maximumSamplingRate = try? container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        maximumBitDepth = try? container.decodeIfPresent(Double.self, forKey: .maximumBitDepth)
        hiresStreamable = try? container.decodeIfPresent(Bool.self, forKey: .hiresStreamable)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        goodies = try? container.decodeIfPresent([QobuzGoodie].self, forKey: .goodies)
        displayable = try? container.decodeIfPresent(Bool.self, forKey: .displayable)
        streamable = try? container.decodeIfPresent(Bool.self, forKey: .streamable)
        downloadable = try? container.decodeIfPresent(Bool.self, forKey: .downloadable)
        qobuzID = try? container.decodeIfPresent(FlexibleID.self, forKey: .qobuzID)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
    }

    var isBrowseAvailable: Bool {
        displayable != false && streamable != false && downloadable != false
    }

    var browseUnavailableReason: String? {
        guard !isBrowseAvailable else { return nil }
        return "Qobuz lists this album in search, but it is not available or downloadable for this account region."
    }
}

struct QobuzTrackResponse: Codable, Equatable {
    let id: FlexibleID
    let title: String
    let version: String?
    let performer: QobuzArtist?
    let album: QobuzAlbumRef
    let duration: Int?
    let parentalWarning: Bool?
    let isrc: String?
    let trackNumber: Int?
    let mediaNumber: Int?
    let work: String?
    let performers: String?
    let displayable: Bool?
    let streamable: Bool?
    let downloadable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, version, performer, album, duration, isrc, work, performers
        case displayable, streamable, downloadable
        case parentalWarning = "parental_warning"
        case trackNumber = "track_number"
        case mediaNumber = "media_number"
    }

    var isBrowseAvailable: Bool {
        displayable != false && streamable != false && downloadable != false
    }
}

struct QobuzArtist: Codable, Equatable {
    let id: FlexibleID?
    let name: String
}

struct QobuzAlbumRef: Codable, Equatable {
    let id: FlexibleID
    let title: String
    let image: QobuzImage?
    let artist: QobuzArtist?
}

struct QobuzImage: Codable, Equatable {
    let large: String?
    let small: String?
    let thumbnail: String?
}

struct QobuzGenre: Codable, Equatable { let name: String }
struct QobuzLabel: Codable, Equatable { let name: String }
struct QobuzTracksContainer: Codable, Equatable {
    let items: [QobuzTrackRef]
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items, total
    }

    init(items: [QobuzTrackRef], total: Int? = nil) {
        self.items = items
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try? container.decodeIfPresent(Int.self, forKey: .total)

        guard var tracks = try? container.nestedUnkeyedContainer(forKey: .items) else {
            items = []
            return
        }

        var decoded: [QobuzTrackRef] = []
        while !tracks.isAtEnd {
            if let track = try? tracks.decode(QobuzTrackRef.self) {
                decoded.append(track)
            } else {
                _ = try? tracks.decode(JSONValue.self)
            }
        }
        items = decoded
    }
}
struct QobuzTrackRef: Codable, Equatable {
    let id: FlexibleID
    let title: String
    let trackNumber: Int?
    let mediaNumber: Int?
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, duration
        case trackNumber = "track_number"
        case mediaNumber = "media_number"
    }

    init(id: FlexibleID, title: String, trackNumber: Int? = nil, mediaNumber: Int? = nil, duration: Int? = nil) {
        self.id = id
        self.title = title
        self.trackNumber = trackNumber
        self.mediaNumber = mediaNumber
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FlexibleID.self, forKey: .id)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "Track \(id.value)"
        trackNumber = try? container.decodeIfPresent(Int.self, forKey: .trackNumber)
        mediaNumber = try? container.decodeIfPresent(Int.self, forKey: .mediaNumber)
        duration = try? container.decodeIfPresent(Int.self, forKey: .duration)
    }
}
struct QobuzGoodie: Codable, Equatable { let url: String }

struct QobuzUserResponse: Codable, Equatable {
    let country: String?
    let credential: Credential?

    struct Credential: Codable, Equatable {
        let parameters: JSONValue?
    }
}

struct QobuzArtistResponse: Codable, Equatable {
    let id: FlexibleID?
    let name: String
    let image: QobuzImage?
    let albums: QobuzArtistAlbums?

    enum CodingKeys: String, CodingKey {
        case id, name, image, albums
    }
}

struct QobuzArtistAlbums: Codable, Equatable {
    let items: [QobuzAlbumResponse]
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([QobuzAlbumResponse].self, forKey: .items) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct QobuzSearchArtist: Codable, Equatable {
    let id: FlexibleID?
    let name: String
    let image: QobuzImage?

    var stableBrowseID: String {
        id?.value ?? name
    }
}

struct QobuzSearchResponse: Codable, Equatable {
    let albums: QobuzSearchItems<QobuzAlbumResponse>?
    let tracks: QobuzSearchItems<QobuzTrackResponse>?
    let artists: QobuzSearchItems<QobuzSearchArtist>?
}

struct QobuzPlaylistResponse: Codable, Equatable {
    let id: FlexibleID?
    let name: String?
    let title: String?
    let tracks: QobuzTracksContainer?
}

struct QobuzFileURLResponse: Codable, Equatable {
    let url: String?
    let formatID: Int?
    let bitDepth: Double?
    let samplingRate: Double?

    enum CodingKeys: String, CodingKey {
        case url
        case formatID = "format_id"
        case bitDepth = "bit_depth"
        case samplingRate = "sampling_rate"
    }

    var hasPlayableURL: Bool {
        guard let url else { return false }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct QobuzSearchItems<T: Codable & Equatable>: Codable, Equatable {
    let items: [T]

    enum CodingKeys: String, CodingKey {
        case items
    }

    init(items: [T]) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard var itemContainer = try? container.nestedUnkeyedContainer(forKey: .items) else {
            items = []
            return
        }

        var decoded: [T] = []
        while !itemContainer.isAtEnd {
            if let item = try? itemContainer.decode(T.self) {
                decoded.append(item)
            } else {
                _ = try? itemContainer.decode(JSONValue.self)
            }
        }
        items = decoded
    }
}

enum SearchType: String {
    case album = "albums"
    case track = "tracks"
    case artist = "artists"
    case playlist = "playlists"
}

struct AlbumPreviewInfo: Equatable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    let trackCount: Int
    let duration: Int?
    let quality: String
    let genre: String
    let explicit: Bool
    let upc: String?
    let coverURL: String
    let coverURLMax: String
    let isHiRes: Bool
    let downloadURL: String
}

struct TrackPreviewInfo: Equatable {
    let id: String
    let title: String
    let artist: String
    let albumId: String
    let albumTitle: String
    let trackNumber: Int
    let discNumber: Int
    let year: Int
    let explicit: Bool
    let coverURL: String
    let coverURLMax: String
    let downloadURL: String
}

struct ArtistPreviewInfo: Equatable {
    let id: String
    let name: String
    let albumCount: Int
    let coverURL: String
    let downloadURL: String
}

struct CollectionPreviewInfo: Equatable {
    let kind: QobuzURLParseResult
    let title: String
    let subtitle: String
    let downloadURL: String

    var actionTitle: String {
        kind.downloadActionTitle
    }

    var iconName: String {
        kind.iconName
    }
}

extension AlbumPreviewInfo {
    init(from album: QobuzAlbumResponse) {
        let versionSuffix = album.version.map { " (\($0))" } ?? ""
        let isHiRes = album.hiresStreamable == true
        let bitDepth = Int(album.maximumBitDepth ?? 16)
        let sampleRate = album.maximumSamplingRate ?? 44.1
        let quality = isHiRes ? "\(bitDepth)-bit / \(sampleRate.cleanString)kHz" : "16-bit / 44.1kHz"
        let cover = album.image?.large ?? album.image?.small ?? album.image?.thumbnail ?? ""

        id = album.id.value
        title = album.title + versionSuffix
        artist = album.artist.name
        year = Int((album.releaseDateOriginal ?? "").prefix(4)) ?? 0
        trackCount = album.tracksCount ?? album.tracks?.items.count ?? 0
        duration = album.duration
        self.quality = quality
        genre = album.genre?.name ?? "Unknown"
        explicit = album.parentalWarning ?? false
        upc = album.upc
        coverURL = cover
        coverURLMax = cover.maximumQobuzCoverURL
        self.isHiRes = isHiRes
        downloadURL = "https://open.qobuz.com/album/\(album.id.value)"
    }
}

extension TrackPreviewInfo {
    init(from track: QobuzTrackResponse, album: QobuzAlbumResponse) {
        let versionSuffix = track.version.map { " (\($0))" } ?? ""
        let albumVersion = album.version.map { " (\($0))" } ?? ""
        let cover = album.image?.large ?? track.album.image?.large ?? ""

        id = track.id.value
        title = track.title + versionSuffix
        artist = track.performer?.name ?? track.album.artist?.name ?? album.artist.name
        albumId = album.id.value
        albumTitle = album.title + albumVersion
        trackNumber = track.trackNumber ?? 0
        discNumber = track.mediaNumber ?? 1
        year = Int((album.releaseDateOriginal ?? "").prefix(4)) ?? 0
        explicit = track.parentalWarning ?? false
        coverURL = cover
        coverURLMax = cover.maximumQobuzCoverURL
        downloadURL = "https://open.qobuz.com/track/\(track.id.value)"
    }
}

extension ArtistPreviewInfo {
    init(from artist: QobuzArtistResponse, fallbackID: String) {
        let cover = artist.image?.large ?? artist.image?.small ?? artist.image?.thumbnail ?? ""
        let resolvedID = artist.id?.value ?? fallbackID

        id = resolvedID
        name = artist.name
        albumCount = artist.albums?.total ?? artist.albums?.items.count ?? 0
        coverURL = cover
        downloadURL = "https://open.qobuz.com/artist/\(resolvedID)"
    }
}

private extension String {
    var maximumQobuzCoverURL: String {
        replacingOccurrences(
            of: #"_\d+\.jpg$"#,
            with: "_org.jpg",
            options: .regularExpression
        )
    }
}

extension Double {
    var cleanString: String {
        rounded() == self ? String(Int(self)) : String(self)
    }
}
