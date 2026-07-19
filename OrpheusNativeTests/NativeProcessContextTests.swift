import Foundation
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

final class NativeProcessContextTests: XCTestCase {
    func testXCTestProcessUsesIsolatedApplicationPaths() {
        XCTAssertTrue(NativeProcessContext.isRunningUnitTests)
        XCTAssertTrue(NativeProcessContext.paths.applicationSupportRoot.path.hasPrefix(NSTemporaryDirectory()))
        XCTAssertTrue(NativeProcessContext.paths.defaultDownloadRoot.path.hasPrefix(NSTemporaryDirectory()))
        XCTAssertFalse(
            NativeProcessContext.paths.applicationSupportRoot.path.contains("Application Support/Orpheus for Mac")
        )
    }

    #if ORPHEUS_UNHOSTED_TESTS
    func testLogicSuiteRunsWithoutAnApplicationHost() {
        XCTAssertEqual(ProcessInfo.processInfo.processName, "xctest")
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
    }
    #endif
}
