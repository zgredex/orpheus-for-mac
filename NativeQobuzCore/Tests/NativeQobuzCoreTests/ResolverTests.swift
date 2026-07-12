import Foundation
import XCTest
@testable import NativeQobuzCore

final class ResolverTests: XCTestCase {
    func testAlbumResolutionPreservesTrackOrderAndContext() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one", "two"])
        let service = FakeQobuzService(albums: [album.id: album])
        let plan = try await QobuzCatalogResolver(service: service).resolve(.album(album.id))

        XCTAssertEqual(plan.title, "Album")
        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["one", "two"])
        XCTAssertEqual(plan.tracks.map(\.position), [1, 2])
        XCTAssertTrue(plan.tracks.allSatisfy { $0.total == 2 })
    }

    func testPlaylistFetchesEachAlbumOnceAndPreservesDuplicateTracks() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one", "two"])
        let summary = QobuzAlbumSummary(id: album.id, title: album.title, artist: album.artist)
        let track = QobuzTrack(id: QobuzID("one"), title: "One", album: summary)
        let playlist = QobuzPlaylist(id: QobuzID("playlist"), name: "Favorites", tracks: [track, track])
        let service = FakeQobuzService(albums: [album.id: album], playlists: [playlist.id: playlist])

        let plan = try await QobuzCatalogResolver(service: service).resolve(.playlist(playlist.id))

        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["one", "one"])
        let requestCount = await service.albumRequestCount(for: album.id)
        XCTAssertEqual(requestCount, 1)
    }

    func testArtistDeduplicatesAlbumsAndFlattensCatalogInAlbumOrder() async throws {
        let first = makeAlbum(id: "first", title: "First", trackIDs: ["one", "two"])
        let second = makeAlbum(id: "second", title: "Second", trackIDs: ["three"])
        let artist = QobuzArtistCatalog(
            id: QobuzID("artist"),
            name: "Artist",
            albums: [first, first, second]
        )
        let service = FakeQobuzService(
            albums: [first.id: first, second.id: second],
            artists: [artist.id: artist]
        )

        let plan = try await QobuzCatalogResolver(service: service).resolve(.artist(artist.id))

        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["one", "two", "three"])
        let firstCount = await service.albumRequestCount(for: first.id)
        let secondCount = await service.albumRequestCount(for: second.id)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
    }

    func testTrackResolutionFetchesCanonicalAlbum() async throws {
        let album = makeAlbum(id: "album", trackIDs: ["one"])
        let summary = QobuzAlbumSummary(id: album.id, title: album.title, artist: album.artist)
        let track = QobuzTrack(id: QobuzID("one"), title: "One", album: summary)
        let service = FakeQobuzService(tracks: [track.id: track], albums: [album.id: album])

        let plan = try await QobuzCatalogResolver(service: service).resolve(.track(track.id))

        XCTAssertEqual(plan.tracks.count, 1)
        XCTAssertEqual(plan.tracks[0].album.id, album.id)
    }

    func testAlbumResolutionExcludesTracksBlockedForTheAccountRegion() async throws {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        let available = QobuzTrack(id: QobuzID("available"), title: "Available", performer: artist)
        let blocked = QobuzTrack(
            id: QobuzID("blocked"),
            title: "Blocked",
            performer: artist,
            streamable: false,
            downloadable: true
        )
        let album = QobuzAlbum(
            id: QobuzID("album"),
            title: "Mixed availability",
            artist: artist,
            tracks: [available, blocked]
        )
        let service = FakeQobuzService(albums: [album.id: album])

        let plan = try await QobuzCatalogResolver(service: service).resolve(.album(album.id))

        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["available"])
        XCTAssertEqual(plan.tracks.first?.position, 1)
        XCTAssertEqual(plan.tracks.first?.total, 1)
    }
}

func makeAlbum(id: String, title: String = "Album", trackIDs: [String]) -> QobuzAlbum {
    let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
    let tracks = trackIDs.enumerated().map { offset, id in
        QobuzTrack(
            id: QobuzID(id),
            title: id.capitalized,
            performer: artist,
            trackNumber: offset + 1,
            mediaNumber: 1
        )
    }
    return QobuzAlbum(
        id: QobuzID(id),
        title: title,
        artist: artist,
        tracks: tracks,
        tracksCount: tracks.count,
        mediaCount: 1,
        releaseDate: "2025-01-01"
    )
}

actor FakeQobuzService: QobuzCatalogService {
    private let tracks: [QobuzID: QobuzTrack]
    private let albums: [QobuzID: QobuzAlbum]
    private let playlists: [QobuzID: QobuzPlaylist]
    private let artists: [QobuzID: QobuzArtistCatalog]
    private var albumRequests: [QobuzID: Int] = [:]

    init(
        tracks: [QobuzID: QobuzTrack] = [:],
        albums: [QobuzID: QobuzAlbum] = [:],
        playlists: [QobuzID: QobuzPlaylist] = [:],
        artists: [QobuzID: QobuzArtistCatalog] = [:]
    ) {
        self.tracks = tracks
        self.albums = albums
        self.playlists = playlists
        self.artists = artists
    }

    func validateAccount() async throws -> String { "FR" }

    func track(id: QobuzID) async throws -> QobuzTrack {
        try value(tracks[id], name: "track \(id)")
    }

    func album(id: QobuzID) async throws -> QobuzAlbum {
        albumRequests[id, default: 0] += 1
        return try value(albums[id], name: "album \(id)")
    }

    func playlist(id: QobuzID) async throws -> QobuzPlaylist {
        try value(playlists[id], name: "playlist \(id)")
    }

    func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        try value(artists[id], name: "artist \(id)")
    }

    func fileInfo(trackID: QobuzID, quality: QobuzQuality) async throws -> QobuzFileInfo {
        QobuzFileInfo(url: URL(string: "https://media.example/\(trackID).flac")!, formatID: quality.formatID)
    }

    func albumRequestCount(for id: QobuzID) -> Int { albumRequests[id, default: 0] }

    private func value<T>(_ value: T?, name: String) throws -> T {
        guard let value else { throw NativeQobuzError.invalidResponse("Missing fake \(name)") }
        return value
    }
}
