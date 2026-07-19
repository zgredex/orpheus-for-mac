import SwiftUI
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class LayoutPolicyTests: XCTestCase {
    func testActivityPaneUsesContentAwareCompactHeights() {
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 0), 103)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 1), 115)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 2), 189)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 3), 263)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 20), 263)
    }

    func testLongEditorialCopyUsesSideBySideHeaderAtDesktopWidth() {
        let view = PreviewScaffold(
            header: PreviewHeader(
                title: "30",
                subtitle: "Adele",
                metadata: ["Album", "2021", "Pop/Rock", "12 tracks", "Columbia"]
            ),
            headerAccessory: {
                EditorialHeroPanel(
                    heading: "About this album",
                    summary: nil,
                    editorialDescription: String(repeating: "Long Qobuz editorial copy. ", count: 80)
                )
            }
        ) {
            EmptyView()
        }
        .frame(width: 1_100)

        let renderer = ImageRenderer(content: view)
        let renderedHeight = renderer.nsImage?.size.height

        XCTAssertNotNil(renderedHeight)
        XCTAssertLessThan(renderedHeight ?? .greatestFiniteMagnitude, 250)
    }
}
