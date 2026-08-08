import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeCatalogSearchControllerTests: XCTestCase {
    func testLastCategoryFailureStillSelectsFirstNonemptyCategory() async throws {
        let gate = SearchSettlementGate()
        let controller = NativeCatalogSearchController()
        controller.configure(client: ControlledSearchService(gate: gate))

        try controller.search("Adele")
        for _ in 0..<100 {
            if await gate.waitingCount == NativeBrowseCategory.allCases.count { break }
            await Task.yield()
        }
        let waitingCount = await gate.waitingCount
        XCTAssertEqual(waitingCount, NativeBrowseCategory.allCases.count)

        await settle(.albums, gate: gate, controller: controller)
        await settle(.artists, gate: gate, controller: controller)
        await settle(.playlists, gate: gate, controller: controller)
        await settle(.tracks, gate: gate, controller: controller)

        XCTAssertFalse(controller.isLoading)
        XCTAssertEqual(controller.results.artists.map(\.name), ["Adele"])
        XCTAssertEqual(controller.category, .artists)
        XCTAssertNotNil(controller.errors[.tracks])
    }

    private func settle(
        _ category: NativeBrowseCategory,
        gate: SearchSettlementGate,
        controller: NativeCatalogSearchController
    ) async {
        await gate.release(category.coreValue)
        for _ in 0..<100 where controller.loadingCategories.contains(category) {
            await Task.yield()
        }
    }
}

private enum ControlledSearchFailure: Error {
    case tracks
}

private final class ControlledSearchService: FakeQobuzService, @unchecked Sendable {
    private let gate: SearchSettlementGate

    init(gate: SearchSettlementGate) {
        self.gate = gate
        super.init()
    }

    override func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int,
        offset: Int
    ) async throws -> QobuzSearchResults {
        await gate.wait(for: category)
        switch category {
        case .albums, .playlists:
            return QobuzSearchResults()
        case .artists:
            return QobuzSearchResults(artists: [QobuzArtist(id: QobuzID("adele"), name: "Adele")])
        case .tracks:
            throw ControlledSearchFailure.tracks
        }
    }
}

private actor SearchSettlementGate {
    private var continuations: [QobuzSearchCategory: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<QobuzSearchCategory> = []

    var waitingCount: Int { continuations.count }

    func wait(for category: QobuzSearchCategory) async {
        if released.remove(category) != nil { return }
        await withCheckedContinuation { continuation in
            continuations[category] = continuation
        }
    }

    func release(_ category: QobuzSearchCategory) {
        if let continuation = continuations.removeValue(forKey: category) {
            continuation.resume()
        } else {
            released.insert(category)
        }
    }
}
