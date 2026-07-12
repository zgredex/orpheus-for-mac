import XCTest
@testable import NativeQobuzCore

final class QobuzLinkParserTests: XCTestCase {
    func testParsesCanonicalRegionalAndInterpreterLinks() {
        XCTAssertEqual(
            QobuzLinkParser.parse("https://open.qobuz.com/album/abc")?.request,
            .album(QobuzID("abc"))
        )
        XCTAssertEqual(
            QobuzLinkParser.parse("https://www.qobuz.com/us-en/album/visitor/je3x92urb9drs?ref=1")?.request,
            .album(QobuzID("je3x92urb9drs"))
        )
        XCTAssertEqual(
            QobuzLinkParser.parse("https://www.qobuz.com/fr-fr/interpreter/sienna-spiro/22407938")?.request,
            .artist(QobuzID("22407938"))
        )
    }

    func testExtractionPreservesOrderAndReportsDuplicatesAndInvalidQobuzURLs() {
        let extraction = QobuzLinkParser.extract(from: """
        First https://open.qobuz.com/track/1,
        duplicate https://play.qobuz.com/track/1
        bad https://open.qobuz.com/thing/2
        ignored https://example.com/music
        last https://open.qobuz.com/playlist/3.
        """)

        XCTAssertEqual(extraction.links.map(\.request), [.track(QobuzID("1")), .playlist(QobuzID("3"))])
        XCTAssertEqual(extraction.duplicateCount, 1)
        XCTAssertEqual(extraction.invalidQobuzURLs.count, 1)
        XCTAssertEqual(extraction.ignoredURLCount, 1)
    }
}
