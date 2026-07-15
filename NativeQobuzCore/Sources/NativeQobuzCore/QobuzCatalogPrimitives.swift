import Foundation

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(roles, forKey: .roles)
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
    public let extraLarge: URL?
    public let mega: URL?
    public let small: URL?
    public let thumbnail: URL?
    public let back: URL?

    enum CodingKeys: String, CodingKey {
        case large, mega, small, thumbnail, back
        case extraLarge = "extralarge"
    }

    public init(
        large: URL? = nil,
        extraLarge: URL? = nil,
        mega: URL? = nil,
        small: URL? = nil,
        thumbnail: URL? = nil,
        back: URL? = nil
    ) {
        self.large = large
        self.extraLarge = extraLarge
        self.mega = mega
        self.small = small
        self.thumbnail = thumbnail
        self.back = back
    }

    public var bestURL: URL? { mega ?? extraLarge ?? large ?? small ?? thumbnail }
}

/// A forward-compatible Qobuz release classification used for catalog display
/// and filtering. Unknown server values remain valid instead of breaking the
/// entire album response.
public struct QobuzReleaseType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let album = Self(rawValue: "album")
    public static let single = Self(rawValue: "single")
    public static let ep = Self(rawValue: "ep")
    public static let compilation = Self(rawValue: "compilation")
    public static let live = Self(rawValue: "live")
    public static let epSingle = Self(rawValue: "ep-single")
}

/// Editorial recognition returned by Qobuz. Both the compact current response
/// and the older award/publication response are accepted.
public struct QobuzEditorialAward: Codable, Equatable, Sendable {
    public let id: QobuzID?
    public let name: String
    public let awardedAt: String?

    public init(id: QobuzID? = nil, name: String, awardedAt: String? = nil) {
        self.id = id
        self.name = name
        self.awardedAt = awardedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case awardID = "award_id"
        case awardedAt = "awarded_at"
        case publicationName = "publication_name"
    }

    public init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            id = nil
            name = value
            awardedAt = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(QobuzID.self, forKey: .id)
            ?? container.decodeIfPresent(QobuzID.self, forKey: .awardID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .publicationName)
            ?? "Qobuz award"
        if let value = try? container.decode(String.self, forKey: .awardedAt) {
            awardedAt = value
        } else if let value = try? container.decode(Int64.self, forKey: .awardedAt) {
            awardedAt = String(value)
        } else {
            awardedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(awardedAt, forKey: .awardedAt)
    }
}

/// Shared catalog capability data. These values describe what Qobuz advertises
/// and must never be mistaken for the specifications of a downloaded file.
public struct QobuzCatalogAudioCapabilities: Equatable, Sendable {
    public let maximumBitDepth: Int?
    public let maximumSamplingRate: Double?
    public let maximumChannelCount: Int?

    public init(
        maximumBitDepth: Int? = nil,
        maximumSamplingRate: Double? = nil,
        maximumChannelCount: Int? = nil
    ) {
        self.maximumBitDepth = maximumBitDepth
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumChannelCount = maximumChannelCount
    }
}

public struct QobuzCatalogAvailability: Equatable, Sendable {
    public let streamable: Bool
    public let downloadable: Bool
    public let displayable: Bool
    public let purchasable: Bool?

    public init(
        streamable: Bool,
        downloadable: Bool,
        displayable: Bool = true,
        purchasable: Bool? = nil
    ) {
        self.streamable = streamable
        self.downloadable = downloadable
        self.displayable = displayable
        self.purchasable = purchasable
    }
}

/// Layer 2: a derived, non-persisted view of album data intended for browsing,
/// filtering, and badges. The album/summary remains the only stored source.
public struct QobuzAlbumCatalogMetadata: Equatable, Sendable {
    public let releaseType: QobuzReleaseType?
    public let releaseTags: [String]
    public let genres: [String]
    public let isOfficial: Bool?
    public let releaseDate: String?
    public let subtitle: String?
    public let catchline: String?
    public let editorialDescription: String?
    public let awards: [QobuzEditorialAward]
    public let audioCapabilities: QobuzCatalogAudioCapabilities
    public let availability: QobuzCatalogAvailability

    public init(
        releaseType: QobuzReleaseType? = nil,
        releaseTags: [String] = [],
        genres: [String] = [],
        isOfficial: Bool? = nil,
        releaseDate: String? = nil,
        subtitle: String? = nil,
        catchline: String? = nil,
        editorialDescription: String? = nil,
        awards: [QobuzEditorialAward] = [],
        audioCapabilities: QobuzCatalogAudioCapabilities = .init(),
        availability: QobuzCatalogAvailability
    ) {
        self.releaseType = releaseType
        self.releaseTags = Self.uniqueNonempty(releaseTags)
        self.genres = Self.uniqueNonempty(genres)
        self.isOfficial = isOfficial
        self.releaseDate = releaseDate
        self.subtitle = subtitle
        self.catchline = catchline
        self.editorialDescription = editorialDescription
        self.awards = awards
        self.audioCapabilities = audioCapabilities
        self.availability = availability
    }

    private static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.folding(options: [.caseInsensitive], locale: .current)).inserted else {
                return nil
            }
            return value
        }
    }
}

/// Layer 2 track projection. It deliberately contains catalog display data,
/// not portable audio tags or downloaded-file provenance.
public struct QobuzTrackCatalogMetadata: Equatable, Sendable {
    public let audioCapabilities: QobuzCatalogAudioCapabilities
    public let availability: QobuzCatalogAvailability
    public let copyright: String?

    public init(
        audioCapabilities: QobuzCatalogAudioCapabilities,
        availability: QobuzCatalogAvailability,
        copyright: String?
    ) {
        self.audioCapabilities = audioCapabilities
        self.availability = availability
        self.copyright = copyright
    }
}

/// Layer 2 playlist projection. Standard Qobuz artwork and legacy rectangle
/// artwork are resolved once by the canonical playlist model.
public struct QobuzPlaylistCatalogMetadata: Equatable, Sendable {
    public let artworkURL: URL?
    public let editorialDescription: String?
    public let duration: Int?
    public let createdAt: Int?
    public let updatedAt: Int?
    public let tracksCount: Int?

    public init(
        artworkURL: URL?,
        editorialDescription: String?,
        duration: Int?,
        createdAt: Int?,
        updatedAt: Int?,
        tracksCount: Int?
    ) {
        self.artworkURL = artworkURL
        self.editorialDescription = editorialDescription
        self.duration = duration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tracksCount = tracksCount
    }
}
