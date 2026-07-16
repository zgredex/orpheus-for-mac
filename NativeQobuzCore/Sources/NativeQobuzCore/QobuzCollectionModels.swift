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
    private typealias TracksContainer = QobuzStrictPage<QobuzTrack>

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
        if let decodedName = container.qobuzTolerant(String.self, forKey: .name) {
            name = decodedName
        } else {
            name = try container.decode(String.self, forKey: .title)
        }
        let page = try container.decodeIfPresent(TracksContainer.self, forKey: .tracks)
        tracks = page?.items ?? []
        image = container.qobuzTolerant(QobuzImage.self, forKey: .image)
        owner = container.qobuzTolerant(QobuzPlaylistOwner.self, forKey: .owner)
        createdAt = container.qobuzTolerant(Int.self, forKey: .createdAt)
        updatedAt = container.qobuzTolerant(Int.self, forKey: .updatedAt)
        duration = container.qobuzTolerant(Int.self, forKey: .duration)
        playlistDescription = container.qobuzTolerant(String.self, forKey: .description)
        tracksCount = container.qobuzTolerant(Int.self, forKey: .tracksCount)
        artworkURLs = (
            container.qobuzTolerantArray(URL.self, forKey: .imageRectangle)
            + container.qobuzTolerantArray(URL.self, forKey: .imageRectangleMini)
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
    private typealias AlbumsContainer = QobuzStrictPage<QobuzAlbum>

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
        image = container.qobuzTolerant(QobuzImage.self, forKey: .image)
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
    private typealias AlbumsContainer = QobuzStrictPage<QobuzAlbum>

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
        slug = container.qobuzTolerant(String.self, forKey: .slug)
        let page = try container.decodeIfPresent(AlbumsContainer.self, forKey: .albums)
        albums = page?.items ?? []
        albumsTotal = page?.total
        albumsOffset = page?.offset
        albumsLimit = page?.limit
    }

}
