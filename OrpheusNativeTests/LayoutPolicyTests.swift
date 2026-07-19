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
}
