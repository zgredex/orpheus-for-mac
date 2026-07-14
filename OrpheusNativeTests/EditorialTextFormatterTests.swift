import XCTest
@testable import OrpheusNative

@MainActor
final class EditorialTextFormatterTests: XCTestCase {
    func testQobuzHTMLBecomesReadableNativeText() throws {
        let source = #"<p class="Standard">Une voix <em>très</em> présente&nbsp;: <strong>Adele</strong>. © Qobuz</p>"#
        let value = try XCTUnwrap(EditorialTextFormatter.attributedText(from: source))
        let text = String(value.characters)

        XCTAssertEqual(text, "Une voix très présente : Adele. © Qobuz")
        XCTAssertFalse(text.contains("<p"))
        XCTAssertFalse(text.contains("<em>"))
        XCTAssertFalse(text.contains("&nbsp;"))
    }

    func testPlainEditorialTextIsPreserved() throws {
        let source = "A plain Qobuz editorial note."
        let value = try XCTUnwrap(EditorialTextFormatter.attributedText(from: source))
        XCTAssertEqual(String(value.characters), source)
    }
}
