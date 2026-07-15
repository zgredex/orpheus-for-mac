import Foundation

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
