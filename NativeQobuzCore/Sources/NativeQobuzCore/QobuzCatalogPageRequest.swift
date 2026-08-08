import Foundation

struct QobuzCatalogPageRequest: Sendable {
    let endpoint: String
    let identifierKey: String
    let extra: String

    static let playlist = Self(
        endpoint: "playlist/get",
        identifierKey: "playlist_id",
        extra: "tracks,subscribers,focusAll"
    )

    static let artist = Self(
        endpoint: "artist/get",
        identifierKey: "artist_id",
        extra: "albums,playlists,tracks_appears_on,albums_with_last_release,focusAll"
    )

    static let label = Self(
        endpoint: "label/get",
        identifierKey: "label_id",
        extra: "albums"
    )
}
