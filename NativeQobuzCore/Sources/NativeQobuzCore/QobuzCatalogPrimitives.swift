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

    private enum CodingKeys: String, CodingKey { case id, name, image }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.qobuzTolerant(QobuzID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        image = container.qobuzTolerant(QobuzImage.self, forKey: .image)
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
        roles = container.qobuzTolerantArray(String.self, forKey: .roles)
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.qobuzTolerant(QobuzID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = container.qobuzTolerant(String.self, forKey: .slug)
        albumsCount = container.qobuzTolerant(Int.self, forKey: .albumsCount)
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        large = container.qobuzTolerant(URL.self, forKey: .large)
        extraLarge = container.qobuzTolerant(URL.self, forKey: .extraLarge)
        mega = container.qobuzTolerant(URL.self, forKey: .mega)
        small = container.qobuzTolerant(URL.self, forKey: .small)
        thumbnail = container.qobuzTolerant(URL.self, forKey: .thumbnail)
        back = container.qobuzTolerant(URL.self, forKey: .back)
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
