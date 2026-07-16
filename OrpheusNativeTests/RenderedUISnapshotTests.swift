import Foundation
import SwiftUI
import XCTest
@testable import OrpheusNative

@MainActor
final class RenderedUISnapshotTests: XCTestCase {
    func testAlbumEditorialAcrossDesktopAndCompactAccessibilityLayouts() {
        let desktop = AlbumPreview(
            album: RenderedSnapshotFixtures.longAlbum,
            selectedTrackIDs: Set(RenderedSnapshotFixtures.longAlbum.tracks.map(\.id)),
            onToggleTrackSelection: { _ in },
            onSelectAllTracks: {},
            onClearTrackSelection: {}
        )
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "fr_FR"))

        RenderedSnapshotHarness.assertSnapshot(
            named: "album-editorial-desktop",
            size: CGSize(width: 1_200, height: 620),
            meanTolerance: 0.035,
            content: desktop
        )

        let compact = AlbumPreview(
            album: RenderedSnapshotFixtures.longAlbum,
            selectedTrackIDs: Set(RenderedSnapshotFixtures.longAlbum.tracks.prefix(8).map(\.id)),
            onToggleTrackSelection: { _ in },
            onSelectAllTracks: {},
            onClearTrackSelection: {}
        )
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "pl_PL"))
        .dynamicTypeSize(.accessibility1)

        RenderedSnapshotHarness.assertSnapshot(
            named: "album-editorial-compact-accessibility",
            size: CGSize(width: 720, height: 680),
            meanTolerance: 0.045,
            content: compact
        )
    }

    func testDownloadRecoveryCollapsedAndExpandedStates() throws {
        let fixture = try RenderedSnapshotFixtures.recoveryViewModel()
        defer {
            fixture.viewModel.prepareForTermination()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let activityPane = NativeActivityView()
            .environmentObject(fixture.viewModel)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "pl_PL"))
        RenderedSnapshotHarness.assertSnapshot(
            named: "activity-recovery-pane",
            size: CGSize(width: 1_180, height: 330),
            meanTolerance: 0.04,
            content: activityPane
        )

        let failed = try XCTUnwrap(fixture.viewModel.activities.first)
        let expanded = List {
            ActivityRow(
                activity: failed,
                status: fixture.viewModel.status(for: failed),
                showsDetails: .constant(true)
            )
        }
        .listStyle(.inset)
        .environmentObject(fixture.viewModel)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.accessibility1)
        RenderedSnapshotHarness.assertSnapshot(
            named: "activity-error-details-accessibility",
            size: CGSize(width: 1_000, height: 390),
            meanTolerance: 0.045,
            content: expanded
        )
    }

    func testLibraryProblemsAcrossDesktopAndCompactAccessibilityLayouts() {
        let desktop = LibraryProblemsSnapshotView(snapshot: RenderedSnapshotFixtures.libraryProblems)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_GB"))
        RenderedSnapshotHarness.assertSnapshot(
            named: "library-problems-desktop",
            size: CGSize(width: 1_100, height: 540),
            meanTolerance: 0.04,
            content: desktop
        )

        let compact = LibraryProblemsSnapshotView(snapshot: RenderedSnapshotFixtures.libraryProblems)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "de_DE"))
            .dynamicTypeSize(.accessibility1)
        RenderedSnapshotHarness.assertSnapshot(
            named: "library-problems-compact-accessibility",
            size: CGSize(width: 720, height: 680),
            meanTolerance: 0.05,
            content: compact
        )
    }

    func testSearchPaginationFailureWithLongLocalizedResults() {
        let view = SearchResultsList(
            results: RenderedSnapshotFixtures.searchResults,
            emptyCategory: "Alben und Veröffentlichungen",
            hasMore: true,
            isLoadingMore: false,
            loadMoreError: "Weitere Ergebnisse konnten nach 120 Sekunden nicht geladen werden.",
            loadMore: {}
        )
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "de_DE"))
        .dynamicTypeSize(.xxLarge)
        RenderedSnapshotHarness.assertSnapshot(
            named: "search-pagination-error-localized",
            size: CGSize(width: 820, height: 440),
            meanTolerance: 0.045,
            content: view
        )
    }
}
