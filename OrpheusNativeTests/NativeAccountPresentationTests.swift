import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeAccountPresentationTests: XCTestCase {
    func testSuccessfulConnectionWithoutRegionDoesNotRepeatQobuzName() async throws {
        let fixture = NativeViewModelTestFixture(
            credentials: .complete,
            service: RegionlessQobuzService()
        )
        let viewModel = fixture.viewModel
        try await viewModel.account.load()

        await viewModel.testConnection(showSuccess: true)

        XCTAssertEqual(viewModel.notice, "Connected to Qobuz.")
    }
}

private final class RegionlessQobuzService: FakeQobuzService, @unchecked Sendable {
    override func validateAccount() async throws -> String? { nil }
}
