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

    func testPlaylistAlbumResolutionUsesBoundedConcurrencyAndKeepsTrackOrder() async throws {
        let albums = (0..<9).map { index in
            makeAlbum(id: "album-\(index)", title: "Album \(index)", trackIDs: ["track-\(index)"])
        }
        let tracks = albums.reversed().map { album in
            QobuzTrack(
                id: album.tracks[0].id,
                title: album.tracks[0].title,
                album: QobuzAlbumSummary(id: album.id, title: album.title, artist: album.artist)
            )
        }
        let playlist = QobuzPlaylist(id: QobuzID("playlist"), name: "Ordered", tracks: tracks)
        let service = DelayedPlaylistService(playlist: playlist, albums: albums)

        let plan = try await QobuzCatalogResolver(service: service).resolve(.playlist(playlist.id))

        XCTAssertEqual(plan.tracks.map(\.track.id), tracks.map(\.id))
        let peak = await service.peakConcurrentAlbumRequests
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 6)
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
        let notPurchasable = QobuzTrack(
            id: QobuzID("not-purchasable"),
            title: "Not purchasable",
            performer: artist,
            purchasable: false
        )
        let album = QobuzAlbum(
            id: QobuzID("album"),
            title: "Mixed availability",
            artist: artist,
            tracks: [available, blocked, notPurchasable]
        )
        let service = FakeQobuzService(albums: [album.id: album])

        let plan = try await QobuzCatalogResolver(service: service).resolve(.album(album.id))

        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["available"])
        XCTAssertEqual(plan.tracks.first?.position, 1)
        XCTAssertEqual(plan.tracks.first?.total, 1)
    }

    func testArtistAlbumResolutionUsesBoundedConcurrencyAndKeepsCatalogOrder() async throws {
        let albums = (0..<9).map { index in
            makeAlbum(id: "album-\(index)", title: "Album \(index)", trackIDs: ["track-\(index)"])
        }
        let artist = QobuzArtistCatalog(
            id: QobuzID("artist"),
            name: "Artist",
            albums: albums
        )
        let service = DelayedArtistService(artist: artist, albums: albums)

        let plan = try await QobuzCatalogResolver(service: service).resolve(.artist(artist.id))

        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), albums.map { $0.tracks[0].id.rawValue })
        let peak = await service.peakConcurrentAlbumRequests
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 6)
    }

    func testArtistResolutionDownloadsOnlyAvailableOfficialReleases() async throws {
        let official = makeAlbum(id: "official", title: "Official", trackIDs: ["one"])
        let otherArtist = QobuzArtist(id: QobuzID("other"), name: "Tribute Artist")
        let appearance = QobuzAlbum(
            id: QobuzID("appearance"),
            title: "Appearance",
            artist: otherArtist,
            tracks: [QobuzTrack(id: QobuzID("cover"), title: "Cover", performer: otherArtist)]
        )
        let unavailable = QobuzAlbum(
            id: QobuzID("unavailable"),
            title: "Unavailable",
            artist: official.artist,
            tracks: [QobuzTrack(id: QobuzID("blocked"), title: "Blocked", performer: official.artist)],
            streamable: false
        )
        let artist = QobuzArtistCatalog(
            id: QobuzID("artist"),
            name: "Artist",
            albums: [official, appearance, unavailable]
        )
        let service = FakeQobuzService(
            albums: [official.id: official, appearance.id: appearance, unavailable.id: unavailable],
            artists: [artist.id: artist]
        )

        let plan = try await QobuzCatalogResolver(service: service).resolve(.artist(artist.id))

        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["one"])
        let officialRequests = await service.albumRequestCount(for: official.id)
        let appearanceRequests = await service.albumRequestCount(for: appearance.id)
        let unavailableRequests = await service.albumRequestCount(for: unavailable.id)
        XCTAssertEqual(officialRequests, 1)
        XCTAssertEqual(appearanceRequests, 0)
        XCTAssertEqual(unavailableRequests, 0)
    }

    func testLabelResolutionDownloadsAvailableAlbumsInCatalogOrder() async throws {
        let first = makeAlbum(id: "first", title: "First", trackIDs: ["one"])
        let second = makeAlbum(id: "second", title: "Second", trackIDs: ["two"])
        let blocked = QobuzAlbum(
            id: QobuzID("blocked"),
            title: "Blocked",
            artist: first.artist,
            streamable: false
        )
        let label = QobuzLabelCatalog(
            id: QobuzID("label"),
            name: "Independent Label",
            albums: [first, blocked, second]
        )
        let service = FakeQobuzService(
            albums: [first.id: first, second.id: second],
            labels: [label.id: label]
        )

        let plan = try await QobuzCatalogResolver(service: service).resolve(.label(label.id))

        XCTAssertEqual(plan.title, "Independent Label")
        XCTAssertEqual(plan.tracks.map(\.track.id.rawValue), ["one", "two"])
        XCTAssertTrue(plan.tracks.allSatisfy {
            if case .label(let id, _) = $0.collection { return id == label.id }
            return false
        })
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
    private let labels: [QobuzID: QobuzLabelCatalog]
    private let fileInfos: [QobuzID: QobuzFileInfo]
    private var albumRequests: [QobuzID: Int] = [:]
    private var fileInfoRequests = 0
    private var requestedFormats: [QobuzAudioFormat] = []

    init(
        tracks: [QobuzID: QobuzTrack] = [:],
        albums: [QobuzID: QobuzAlbum] = [:],
        playlists: [QobuzID: QobuzPlaylist] = [:],
        artists: [QobuzID: QobuzArtistCatalog] = [:],
        labels: [QobuzID: QobuzLabelCatalog] = [:],
        fileInfos: [QobuzID: QobuzFileInfo] = [:]
    ) {
        self.tracks = tracks
        self.albums = albums
        self.playlists = playlists
        self.artists = artists
        self.labels = labels
        self.fileInfos = fileInfos
    }

    func validateAccount() async throws -> String? { "FR" }

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

    func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        try value(labels[id], name: "label \(id)")
    }

    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo {
        fileInfoRequests += 1
        requestedFormats.append(format)
        if let fileInfo = fileInfos[trackID] { return fileInfo }
        return QobuzFileInfo(
            url: URL(string: "https://media.example/\(trackID).flac?signature=\(fileInfoRequests)")!,
            format: format
        )
    }

    func albumRequestCount(for id: QobuzID) -> Int { albumRequests[id, default: 0] }
    var fileInfoRequestCount: Int { fileInfoRequests }
    var fileInfoRequestedFormats: [QobuzAudioFormat] { requestedFormats }

    private func value<T>(_ value: T?, name: String) throws -> T {
        guard let value else { throw NativeQobuzError.invalidResponse("Missing fake \(name)") }
        return value
    }
}

private actor DelayedAlbumLookup {
    private let albums: [QobuzID: QobuzAlbum]
    private var activeAlbumRequests = 0
    private(set) var peakConcurrentAlbumRequests = 0

    init(albums: [QobuzAlbum]) {
        self.albums = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
    }

    func album(id: QobuzID) async throws -> QobuzAlbum {
        activeAlbumRequests += 1
        peakConcurrentAlbumRequests = max(peakConcurrentAlbumRequests, activeAlbumRequests)
        defer { activeAlbumRequests -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        guard let album = albums[id] else { throw NativeQobuzError.unavailable("Missing album") }
        return album
    }
}

private actor DelayedArtistService: QobuzCatalogService {
    private let artistValue: QobuzArtistCatalog
    private let albumLookup: DelayedAlbumLookup

    init(artist: QobuzArtistCatalog, albums: [QobuzAlbum]) {
        artistValue = artist
        albumLookup = DelayedAlbumLookup(albums: albums)
    }

    var peakConcurrentAlbumRequests: Int {
        get async { await albumLookup.peakConcurrentAlbumRequests }
    }

    func validateAccount() async throws -> String? { "FR" }
    func track(id: QobuzID) async throws -> QobuzTrack { throw NativeQobuzError.unavailable("Unused") }
    func album(id: QobuzID) async throws -> QobuzAlbum { try await albumLookup.album(id: id) }

    func playlist(id: QobuzID) async throws -> QobuzPlaylist { throw NativeQobuzError.unavailable("Unused") }
    func artist(id: QobuzID) async throws -> QobuzArtistCatalog { artistValue }

    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo {
        throw NativeQobuzError.unavailable("Unused")
    }
}

private actor DelayedPlaylistService: QobuzCatalogService {
    private let playlistValue: QobuzPlaylist
    private let albumLookup: DelayedAlbumLookup

    init(playlist: QobuzPlaylist, albums: [QobuzAlbum]) {
        playlistValue = playlist
        albumLookup = DelayedAlbumLookup(albums: albums)
    }

    var peakConcurrentAlbumRequests: Int {
        get async { await albumLookup.peakConcurrentAlbumRequests }
    }

    func validateAccount() async throws -> String? { "FR" }
    func track(id: QobuzID) async throws -> QobuzTrack { throw NativeQobuzError.unavailable("Unused") }
    func album(id: QobuzID) async throws -> QobuzAlbum { try await albumLookup.album(id: id) }

    func playlist(id: QobuzID) async throws -> QobuzPlaylist { playlistValue }
    func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        throw NativeQobuzError.unavailable("Unused")
    }

    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo {
        throw NativeQobuzError.unavailable("Unused")
    }
}
