import Foundation

public struct QobuzPlaylist: Decodable, Equatable, Sendable {
    public let id: QobuzID
    public let name: String
    public let tracks: [QobuzTrack]
    public let image: QobuzImage?
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
        case id, name, title, tracks, owner, duration, description, image
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
        image: QobuzImage? = nil,
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
        self.image = image
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
        image = try container.decodeIfPresent(QobuzImage.self, forKey: .image)
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

    public var artworkURL: URL? { image?.bestURL ?? artworkURLs.first }
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

public extension QobuzCatalogAvailability {
    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        if !displayable { return .notDisplayable }
        if !streamable { return .notStreamable }
        if purchasable == false { return .notPurchasable }
        return nil
    }
}

public extension QobuzAlbumSummary {
    var catalogMetadata: QobuzAlbumCatalogMetadata {
        QobuzAlbumCatalogMetadata(
            releaseType: releaseType,
            releaseTags: releaseTags,
            genres: genresList.isEmpty ? [genre].compactMap { $0 } : genresList,
            isOfficial: isOfficial,
            releaseDate: releaseDate,
            subtitle: subtitle,
            awards: awards,
            audioCapabilities: QobuzCatalogAudioCapabilities(
                maximumBitDepth: maximumBitDepth,
                maximumSamplingRate: maximumSamplingRate,
                maximumChannelCount: maximumChannelCount
            ),
            availability: QobuzCatalogAvailability(
                streamable: streamable,
                downloadable: downloadable,
                displayable: displayable,
                purchasable: purchasable
            )
        )
    }

    var albumArtistDisplayName: String {
        let value = mainArtists.map(\.name).joined(separator: ", ")
        return value.isEmpty ? (artist?.name ?? "Unknown Artist") : value
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        catalogMetadata.availability.accountAvailabilityIssue
    }
}

public extension QobuzTrack {
    var catalogMetadata: QobuzTrackCatalogMetadata {
        QobuzTrackCatalogMetadata(
            audioCapabilities: QobuzCatalogAudioCapabilities(
                maximumBitDepth: maximumBitDepth,
                maximumSamplingRate: maximumSamplingRate,
                maximumChannelCount: maximumChannelCount
            ),
            availability: QobuzCatalogAvailability(
                streamable: streamable,
                downloadable: downloadable,
                purchasable: purchasable
            ),
            copyright: copyright
        )
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        catalogMetadata.availability.accountAvailabilityIssue
    }
}

public extension QobuzAlbum {
    var catalogMetadata: QobuzAlbumCatalogMetadata {
        QobuzAlbumCatalogMetadata(
            releaseType: releaseType,
            releaseTags: releaseTags,
            genres: genresList.isEmpty ? [genre].compactMap { $0 } : genresList,
            isOfficial: isOfficial,
            releaseDate: releaseDate,
            subtitle: subtitle,
            catchline: catchline,
            editorialDescription: albumDescription,
            awards: awards,
            audioCapabilities: QobuzCatalogAudioCapabilities(
                maximumBitDepth: maximumBitDepth,
                maximumSamplingRate: maximumSamplingRate,
                maximumChannelCount: maximumChannelCount
            ),
            availability: QobuzCatalogAvailability(
                streamable: streamable,
                downloadable: downloadable,
                displayable: displayable,
                purchasable: purchasable
            )
        )
    }

    var albumArtistDisplayName: String {
        mainArtists.map(\.name).joined(separator: ", ")
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        catalogMetadata.availability.accountAvailabilityIssue
    }

    var availableTracks: [QobuzTrack] {
        tracks.filter { $0.accountAvailabilityIssue == nil }
    }

    var unavailableTrackCount: Int {
        tracks.count - availableTracks.count
    }
}

public extension QobuzPlaylist {
    var catalogMetadata: QobuzPlaylistCatalogMetadata {
        QobuzPlaylistCatalogMetadata(
            artworkURL: artworkURL,
            editorialDescription: playlistDescription,
            duration: duration,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tracksCount: tracksCount ?? tracksTotal ?? tracks.count
        )
    }

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
