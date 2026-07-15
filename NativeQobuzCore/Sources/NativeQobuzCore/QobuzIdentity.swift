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

/// The user's download policy. Each case is a maximum: Qobuz may deliver a
/// lower exact format when the requested ceiling is unavailable.
public enum QobuzQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case mp3 = "high"
    case lossless
    case hiRes = "hifi"

    public var maximumFormat: QobuzAudioFormat {
        switch self {
        case .mp3: .mp3
        case .lossless: .lossless
        case .hiRes: .hiRes
        }
    }
}

/// An exact Qobuz audio format used on the wire and recorded in provenance.
/// Unlike `QobuzQuality`, this is not a user preference or fallback policy.
public enum QobuzAudioFormat: Int, Codable, CaseIterable, Sendable, Hashable {
    case mp3 = 5
    case lossless = 6
    case hiRes96 = 7
    case hiRes = 27

    public var formatID: Int { rawValue }

    public init?(formatID: Int) {
        self.init(rawValue: formatID)
    }

    public var fileExtension: String {
        self == .mp3 ? "mp3" : "flac"
    }

    public var displayName: String {
        switch self {
        case .mp3: "MP3 320 kbps"
        case .lossless: "Lossless FLAC"
        case .hiRes96: "Hi-Res FLAC up to 96 kHz"
        case .hiRes: "Hi-Res FLAC"
        }
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
