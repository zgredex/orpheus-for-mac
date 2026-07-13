import XCTest
@testable import NativeQobuzCore

final class DiscographyTests: XCTestCase {
    func testCatalogSeparatesOfficialReleasesAppearancesAndUnavailableAlbums() {
        let artist = QobuzArtist(id: QobuzID("adele"), name: "Adele")
        let coverArtist = QobuzArtist(id: QobuzID("cover-artist"), name: "Adele Tribute Band")
        let official = album(id: "official", artist: artist)
        let fallbackNameMatch = album(
            id: "fallback",
            artist: QobuzArtist(id: nil, name: "ADÈLE")
        )
        let appearance = album(id: "appearance", artist: coverArtist)
        let unavailable = album(id: "blocked", artist: artist, streamable: false)
        let catalog = QobuzArtistCatalog(
            id: QobuzID("adele"),
            name: "Adele",
            albums: [official, fallbackNameMatch, appearance, unavailable]
        )

        XCTAssertEqual(catalog.officialAlbums.map(\.id.rawValue), ["official", "fallback"])
        XCTAssertEqual(catalog.appearanceAlbums.map(\.id.rawValue), ["appearance"])
        XCTAssertEqual(catalog.availableAlbums.map(\.id.rawValue), ["official", "fallback", "appearance"])
        XCTAssertEqual(catalog.relationship(of: official), .official)
        XCTAssertEqual(catalog.relationship(of: appearance), .appearance)
    }

    private func album(
        id: String,
        artist: QobuzArtist,
        streamable: Bool = true
    ) -> QobuzAlbum {
        QobuzAlbum(
            id: QobuzID(id),
            title: id.capitalized,
            artist: artist,
            tracksCount: 1,
            streamable: streamable,
            displayable: true
        )
    }
}
