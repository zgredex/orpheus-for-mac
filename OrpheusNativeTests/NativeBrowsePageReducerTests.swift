import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

final class NativeBrowsePageReducerTests: XCTestCase {
    func testPlaylistPaginationPreservesRepeatedTrackOccurrences() throws {
        let repeated = QobuzTrack(id: QobuzID("repeat"), title: "Repeat")
        let first = QobuzPlaylist(
            id: QobuzID("playlist"),
            name: "Mix",
            tracks: [repeated],
            tracksTotal: 2,
            tracksOffset: 0,
            tracksLimit: 1
        )
        let second = QobuzPlaylist(
            id: first.id,
            name: first.name,
            tracks: [repeated],
            tracksTotal: 2,
            tracksOffset: nil,
            tracksLimit: 1
        )

        let result = try NativeBrowsePageReducer.append(
            .playlist(second),
            to: .playlist(first),
            pageSize: 1,
            requestedOffset: 1
        )

        guard case .playlist(let playlist) = result.content else {
            return XCTFail("Expected playlist content")
        }
        XCTAssertEqual(playlist.tracks.map(\.id), [repeated.id, repeated.id])
        XCTAssertNil(result.pagination?.nextOffset)
    }

    func testMissingReportedOffsetAdvancesFromRequestedOffset() throws {
        let first = artistPage(albumID: "one", offset: 0)
        let next = artistPage(albumID: "two", offset: nil)

        let result = try NativeBrowsePageReducer.append(
            .artist(next),
            to: .artist(first),
            pageSize: 1,
            requestedOffset: 1
        )

        XCTAssertEqual(result.pagination?.nextOffset, 2)
    }

    func testConcreteMismatchedOffsetIsRejectedBeforeContentMerge() {
        let first = artistPage(albumID: "one", offset: 0)
        let wrong = artistPage(albumID: "three", offset: 2)

        XCTAssertThrowsError(try NativeBrowsePageReducer.append(
            .artist(wrong),
            to: .artist(first),
            pageSize: 1,
            requestedOffset: 1
        ))
    }

    private func artistPage(albumID: String, offset: Int?) -> QobuzArtistCatalog {
        let artistID = QobuzID("artist")
        let artist = QobuzArtist(id: artistID, name: "Artist")
        return QobuzArtistCatalog(
            id: artistID,
            name: artist.name,
            albums: [QobuzAlbum(id: QobuzID(albumID), title: albumID, artist: artist)],
            albumsTotal: 3,
            albumsOffset: offset,
            albumsLimit: 1
        )
    }
}
