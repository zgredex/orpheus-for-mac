import Foundation
import NativeQobuzCore
@testable import OrpheusNative

final class FakeQobuzService: NativeQobuzServicing, @unchecked Sendable {
    private let paginatedSearch: Bool
    private let paginatedCollections: Bool

    init(paginatedSearch: Bool = false, paginatedCollections: Bool = false) {
        self.paginatedSearch = paginatedSearch
        self.paginatedCollections = paginatedCollections
    }

    func validateAccount() async throws -> String? { "FR" }

    func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int,
        offset: Int
    ) async throws -> QobuzSearchResults {
        try await Task.sleep(for: .milliseconds(30))
        if paginatedSearch {
            return paginatedSearchResults(category: category, offset: offset)
        }
        switch category {
        case .albums:
            return QobuzSearchResults(albums: [
                QobuzAlbumSummary(id: .init("30"), title: "30", artist: .init(id: .init("adele"), name: "Adele")),
                QobuzAlbumSummary(id: .init("19"), title: "19", artist: .init(id: .init("adele"), name: "Adele"))
            ])
        case .artists:
            return QobuzSearchResults(artists: [.init(id: .init("adele"), name: "Adele")])
        case .playlists:
            return QobuzSearchResults(playlists: [
                QobuzPlaylist(
                    id: .init("adele-essentials"),
                    name: "Adele Essentials",
                    tracks: [],
                    owner: .init(name: "Qobuz"),
                    tracksCount: 20
                )
            ])
        case .tracks:
            return QobuzSearchResults(tracks: [
                QobuzTrack(id: .init("hello"), title: "Hello", performer: .init(id: .init("adele"), name: "Adele"))
            ])
        }
    }

    func track(id: QobuzID) async throws -> QobuzTrack {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func album(id: QobuzID) async throws -> QobuzAlbum {
        try await Task.sleep(for: .milliseconds(10))
        if id == QobuzID("missing-region") {
            throw NativeQobuzError.unavailable("Album is unavailable for this account region.")
        }
        return QobuzAlbum(
            id: id,
            title: "30",
            artist: .init(id: .init("adele"), name: "Adele"),
            image: QobuzImage(large: URL(string: "https://example.com/30.jpg")),
            tracks: [QobuzTrack(id: .init("easy"), title: "Easy On Me", trackNumber: 1)],
            maximumSamplingRate: 96,
            maximumBitDepth: 24,
            hiresStreamable: true
        )
    }

    func playlist(id: QobuzID) async throws -> QobuzPlaylist {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    func artist(id: QobuzID) async throws -> QobuzArtistCatalog {
        let adele = QobuzArtist(id: id, name: "Adele")
        let other = QobuzArtist(id: QobuzID("other"), name: "Tribute Artist")
        return QobuzArtistCatalog(
            id: id,
            name: "Adele",
            albums: [
                QobuzAlbum(id: QobuzID("official"), title: "30", artist: adele, tracksCount: 12),
                QobuzAlbum(id: QobuzID("appearance"), title: "Adele Covers", artist: other, tracksCount: 10),
                QobuzAlbum(
                    id: QobuzID("blocked"),
                    title: "Blocked",
                    artist: adele,
                    tracksCount: 1,
                    streamable: false
                )
            ]
        )
    }

    func artistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzArtistCatalog {
        guard paginatedCollections else { return try await artist(id: id) }
        let artist = QobuzArtist(id: id, name: "Adele")
        let albums: [QobuzAlbum]
        if offset == 0 {
            albums = [
                QobuzAlbum(id: QobuzID("first"), title: "First", artist: artist),
                QobuzAlbum(id: QobuzID("second"), title: "Second", artist: artist)
            ]
        } else {
            albums = [QobuzAlbum(id: QobuzID("third"), title: "Third", artist: artist)]
        }
        return QobuzArtistCatalog(
            id: id,
            name: artist.name,
            albums: albums,
            albumsTotal: 3,
            albumsOffset: offset,
            albumsLimit: limit
        )
    }

    func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        let artist = QobuzArtist(id: QobuzID("artist"), name: "Artist")
        return QobuzLabelCatalog(
            id: id,
            name: "Test Label",
            albums: [QobuzAlbum(id: QobuzID("release"), title: "Release", artist: artist)]
        )
    }

    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo {
        throw NativeQobuzError.unavailable("Unused by this test")
    }

    private func paginatedSearchResults(
        category: QobuzSearchCategory,
        offset: Int
    ) -> QobuzSearchResults {
        guard category == .tracks else { return QobuzSearchResults(offset: offset, total: 0) }
        if offset == 0 {
            return QobuzSearchResults(
                tracks: [
                    QobuzTrack(id: .init("track-one"), title: "Track One"),
                    QobuzTrack(id: .init("track-two"), title: "Track Two")
                ],
                nextOffset: 2,
                total: 3
            )
        }
        return QobuzSearchResults(
            tracks: [QobuzTrack(id: .init("track-three"), title: "Track Three")],
            offset: offset,
            total: 3
        )
    }
}

final class FakeArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    let snapshot: QobuzArchiveSnapshot
    private let lock = NSLock()
    private var scans = 0

    init(snapshot: QobuzArchiveSnapshot) {
        self.snapshot = snapshot
    }

    var scanCount: Int { lock.withLock { scans } }

    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        lock.withLock { scans += 1 }
        try await Task.sleep(for: .milliseconds(10))
        return snapshot
    }
}
