import Foundation

struct QobuzSearchResponse: Decodable {
    let albums: Items<QobuzAlbumSummary>?
    let artists: Items<QobuzArtist>?
    let playlists: Items<QobuzPlaylist>?
    let tracks: Items<QobuzTrack>?

    typealias Items<Value: Decodable> = QobuzLossyPage<Value>

    private enum CodingKeys: String, CodingKey {
        case albums, artists, playlists, tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albums = container.qobuzTolerant(Items<QobuzAlbumSummary>.self, forKey: .albums)
        artists = container.qobuzTolerant(Items<QobuzArtist>.self, forKey: .artists)
        playlists = container.qobuzTolerant(Items<QobuzPlaylist>.self, forKey: .playlists)
        tracks = container.qobuzTolerant(Items<QobuzTrack>.self, forKey: .tracks)
    }
}

struct QobuzAccountResponse: Decodable {
    let country: String?
    let credential: Credential?

    struct Credential: Decodable {
        let parameters: [String: QobuzJSONFragment]?
    }
}

enum QobuzJSONFragment: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: QobuzJSONFragment])
    case array([QobuzJSONFragment])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: QobuzJSONFragment].self) { self = .object(value) }
        else if let value = try? container.decode([QobuzJSONFragment].self) { self = .array(value) }
        else {
            throw DecodingError.typeMismatch(
                QobuzJSONFragment.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
}
