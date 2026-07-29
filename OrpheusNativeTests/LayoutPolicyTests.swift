import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class LayoutPolicyTests: XCTestCase {
    func testActivityPaneUsesContentAwareCompactHeights() {
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 0), 103)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 1), 145)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 2), 249)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 20), 249)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 1, compact: true), 157)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 2, compact: true), 273)
        XCTAssertEqual(DS.ActivityPane.preferredHeight(activityCount: 2, accessibility: true), 305)
    }
}
