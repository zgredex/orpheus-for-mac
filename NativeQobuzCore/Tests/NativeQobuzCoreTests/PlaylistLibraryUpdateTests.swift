import XCTest
@testable import NativeQobuzCore

final class PlaylistLibraryUpdateTests: XCTestCase {
    func testCompletePlaylistPreservesRepeatedPlayableOccurrences() async throws {
        let fixture = try PlaylistLibraryTestFixture()
        defer { fixture.cleanup() }
        let plan = fixture.plan(
            sourceTrackIDs: ["a", "a", "unavailable"],
            playableTrackIDs: ["a"]
        )
        let paths = ["a": try fixture.path("a")]
        try fixture.seedManagedAudio(for: plan, pathsByTrackID: paths)

        _ = try await fixture.update(plan, pathsByTrackID: paths)
        let second = try await fixture.update(plan, pathsByTrackID: paths)

        try assertProjection(
            fixture: fixture,
            assets: second,
            expectedTrackIDs: ["a", "a"]
        )
        XCTAssertEqual(try fixture.playlistRecord().sourceTrackCount, 3)
    }

    func testFullPlaylistThenSubsetKeepsM3UAndManifestIdentical() async throws {
        let fixture = try PlaylistLibraryTestFixture()
        defer { fixture.cleanup() }
        let complete = fixture.plan(sourceTrackIDs: ["a", "b", "c"])
        let paths = try paths(for: ["a", "b", "c"], fixture: fixture)
        try fixture.seedManagedAudio(for: complete, pathsByTrackID: paths)
        _ = try await fixture.update(complete, pathsByTrackID: paths)

        let selected = try complete.selecting(trackIDs: [QobuzID("b")])
        let result = try await fixture.update(selected, pathsByTrackID: paths)

        try assertProjection(
            fixture: fixture,
            assets: result,
            expectedTrackIDs: ["a", "b", "c"]
        )
    }

    func testDisjointPlaylistSubsetsConvergeInSourceOrder() async throws {
        let fixture = try PlaylistLibraryTestFixture()
        defer { fixture.cleanup() }
        let complete = fixture.plan(sourceTrackIDs: ["a", "b", "c", "d"])
        let paths = try paths(for: ["a", "b", "c", "d"], fixture: fixture)
        try fixture.seedManagedAudio(for: complete, pathsByTrackID: paths)

        let first = try complete.selecting(trackIDs: [QobuzID("a"), QobuzID("c")])
        _ = try await fixture.update(first, pathsByTrackID: paths)
        let second = try complete.selecting(trackIDs: [QobuzID("b"), QobuzID("d")])
        let result = try await fixture.update(second, pathsByTrackID: paths)

        try assertProjection(
            fixture: fixture,
            assets: result,
            expectedTrackIDs: ["a", "b", "c", "d"]
        )
    }

    func testSelectedDuplicateContractionDropsSurplusRetainedOccurrence() async throws {
        let fixture = try PlaylistLibraryTestFixture()
        defer { fixture.cleanup() }
        let initial = fixture.plan(sourceTrackIDs: ["a", "a", "b"])
        let paths = try paths(for: ["a", "b"], fixture: fixture)
        try fixture.seedManagedAudio(for: initial, pathsByTrackID: paths)
        _ = try await fixture.update(initial, pathsByTrackID: paths)

        let revised = fixture.plan(sourceTrackIDs: ["a", "b"])
        let selected = try revised.selecting(trackIDs: [QobuzID("a")])
        let result = try await fixture.update(selected, pathsByTrackID: paths)

        try assertProjection(
            fixture: fixture,
            assets: result,
            expectedTrackIDs: ["a", "b"]
        )
    }

    func testSelectedDuplicateExpansionAddsEveryFreshOccurrenceOnce() async throws {
        let fixture = try PlaylistLibraryTestFixture()
        defer { fixture.cleanup() }
        let initial = fixture.plan(sourceTrackIDs: ["a", "b"])
        let paths = try paths(for: ["a", "b"], fixture: fixture)
        try fixture.seedManagedAudio(for: initial, pathsByTrackID: paths)
        _ = try await fixture.update(initial, pathsByTrackID: paths)

        let revised = fixture.plan(sourceTrackIDs: ["a", "a", "b"])
        let selected = try revised.selecting(trackIDs: [QobuzID("a")])
        let result = try await fixture.update(selected, pathsByTrackID: paths)

        try assertProjection(
            fixture: fixture,
            assets: result,
            expectedTrackIDs: ["a", "a", "b"]
        )
    }

    func testSelectedTrackReplacementRemovesOldPhysicalMembership() async throws {
        let fixture = try PlaylistLibraryTestFixture()
        defer { fixture.cleanup() }
        let complete = fixture.plan(sourceTrackIDs: ["a", "b"])
        let oldA = try fixture.path("a", variant: "old")
        let newA = try fixture.path("a", variant: "new")
        let pathB = try fixture.path("b")
        let initialPaths = ["a": oldA, "b": pathB]
        try fixture.seedManagedAudio(for: complete, pathsByTrackID: initialPaths)
        _ = try await fixture.update(complete, pathsByTrackID: initialPaths)

        let selected = try complete.selecting(trackIDs: [QobuzID("a")])
        try fixture.seedManagedAudio(for: selected.tracks[0], at: newA)
        let result = try await fixture.update(
            selected,
            pathsByTrackID: ["a": newA, "b": pathB]
        )

        try assertProjection(
            fixture: fixture,
            assets: result,
            expectedTrackIDs: ["a", "b"]
        )
        let record = try fixture.playlistRecord()
        XCTAssertEqual(record.trackPaths, [newA.rawValue, pathB.rawValue])
        XCTAssertFalse(record.trackPaths.contains(oldA.rawValue))
    }

    private func paths(
        for trackIDs: [String],
        fixture: PlaylistLibraryTestFixture
    ) throws -> [String: LibraryRelativePath] {
        try Dictionary(uniqueKeysWithValues: trackIDs.map { ($0, try fixture.path($0)) })
    }

    private func assertProjection(
        fixture: PlaylistLibraryTestFixture,
        assets: QobuzLibraryCollectionAssets,
        expectedTrackIDs: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let playlistURL = try XCTUnwrap(assets.playlistURL, file: file, line: line)
        let record = try fixture.playlistRecord()
        let m3uPaths = try fixture.resolvedM3UPaths(at: playlistURL)
        XCTAssertEqual(m3uPaths, record.trackPaths, file: file, line: line)
        XCTAssertEqual(
            try fixture.trackIDs(for: record.trackPaths),
            expectedTrackIDs,
            file: file,
            line: line
        )
    }
}
