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

    func testEditorialContentSuppressesEquivalentSummaryAndDescription() throws {
        let content = EditorialContent(
            summary: "A concise album note.",
            editorialDescription: "<p>A concise album note.</p>"
        )

        XCTAssertEqual(try XCTUnwrap(EditorialContent.plainText(content.summary)), "A concise album note.")
        XCTAssertNil(content.description)
    }

    func testLongEditorialContentUsesDedicatedReader() {
        let content = EditorialContent(
            summary: nil,
            editorialDescription: String(repeating: "Long-form Qobuz editorial copy. ", count: 12)
        )

        XCTAssertTrue(content.benefitsFromReader)
        XCTAssertTrue(content.descriptionCanExpand)
    }
}
