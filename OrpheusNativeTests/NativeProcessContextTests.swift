import Foundation
import XCTest
@testable import OrpheusNative

final class NativeProcessContextTests: XCTestCase {
    func testXCTestHostUsesIsolatedApplicationPaths() {
        XCTAssertTrue(NativeProcessContext.isRunningUnitTests)
        XCTAssertTrue(NativeProcessContext.paths.applicationSupportRoot.path.hasPrefix(NSTemporaryDirectory()))
        XCTAssertTrue(NativeProcessContext.paths.defaultDownloadRoot.path.hasPrefix(NSTemporaryDirectory()))
        XCTAssertFalse(
            NativeProcessContext.paths.applicationSupportRoot.path.contains("Application Support/Orpheus for Mac")
        )
    }
}
