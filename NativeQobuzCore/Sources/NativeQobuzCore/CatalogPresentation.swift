import Foundation

public extension QobuzQuality {
    var displayName: String { maximumFormat.displayName }
}

public extension QobuzAlbum {
    var mainArtists: [QobuzArtistCredit] {
        resolvedMainArtists(artists, fallback: artist)
    }
}

public extension QobuzAlbumSummary {
    var mainArtists: [QobuzArtistCredit] {
        resolvedMainArtists(artists, fallback: artist)
    }
}

private func resolvedMainArtists(
    _ artists: [QobuzArtistCredit],
    fallback: QobuzArtist?
) -> [QobuzArtistCredit] {
    let primary = artists.filter(\.isMainArtist)
    if !primary.isEmpty { return primary }
    return fallback.map { [QobuzArtistCredit(id: $0.id, name: $0.name)] } ?? []
}
