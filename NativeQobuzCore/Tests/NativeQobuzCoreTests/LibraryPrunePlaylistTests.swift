import XCTest
@testable import NativeQobuzCore

final class LibraryPrunePlaylistTests: XCTestCase {
    func testPruneRewritesManagedPlaylistAndRemovesEveryDuplicateOccurrence() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let scenario = try await fixture.writePlaylistWithDuplicateProblem()

        let result = try await QobuzLibraryPruner(scanner: QobuzArchiveScanner()).pruneProblems(
            at: fixture.source,
            snapshot: scenario.snapshot
        )

        let manifest = try QobuzLibraryManifestIO.load(at: fixture.source)
        let playlist = try XCTUnwrap(manifest.collections.first { $0.kind == .playlist })
        XCTAssertEqual(playlist.trackPaths, [fixture.secondAudioPath])
        let contents = try scenario.fileSystem.readString(scenario.playlistPath)
        XCTAssertEqual(
            QobuzM3UPlaylist.entries(in: contents),
            [QobuzM3UPlaylist.Entry(
                path: "../../\(fixture.secondAudioPath)",
                extendedInfo: "#EXTINF:202,Keeper - Retained presentation"
            )]
        )
        XCTAssertEqual(
            QobuzM3UPlaylist.resolvedRelativePaths(
                in: contents,
                playlistFolder: scenario.fileSystem.displayURL(for: scenario.playlistPath.parent),
                libraryRoot: fixture.source
            ),
            playlist.trackPaths
        )
        XCTAssertEqual(result.removedTrackCount, 1)
        XCTAssertEqual(result.snapshot.collections, manifest.collections)
    }

    func testPruneRollsBackPlaylistManifestAndAudioWhenM3UReplacementFails() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let scenario = try await fixture.writePlaylistWithDuplicateProblem()
        let managedPaths = fixture.twoTrackManagedPaths + [scenario.playlistPath.rawValue]
        let before = try fixture.contents(at: managedPaths)
        let pruner = QobuzLibraryPruner(
            scanner: QobuzArchiveScanner(),
            faultInjector: { checkpoint in
                if case .appliedMutation(let path) = checkpoint,
                   path == scenario.playlistPath {
                    throw PlaylistPruneFailure.stop
                }
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await pruner.pruneProblems(
                at: fixture.source,
                snapshot: scenario.snapshot
            )
        }

        XCTAssertEqual(try fixture.contents(at: managedPaths), before)
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testPruneRemovesManagedM3UWhenNoPlaylistOccurrencesRemain() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let scenario = try await fixture.writePlaylistWithDuplicateProblem()
        try Data("second track changed".utf8).write(
            to: fixture.source.appendingPathComponent(fixture.secondAudioPath)
        )
        let snapshot = try await QobuzArchiveScanner().scan(root: fixture.source)

        let result = try await QobuzLibraryPruner(scanner: QobuzArchiveScanner()).pruneProblems(
            at: fixture.source,
            snapshot: snapshot
        )

        XCTAssertNil(try scenario.fileSystem.metadata(at: scenario.playlistPath))
        XCTAssertFalse(result.snapshot.collections.contains { $0.kind == .playlist })
        XCTAssertEqual(result.removedTrackCount, 2)
    }

    func testPruneRejectsManagedM3USymlinkWithoutTouchingItsTargetOrAudio() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let scenario = try await fixture.writePlaylistWithDuplicateProblem()
        let sentinel = fixture.outside.appendingPathComponent("sentinel.m3u")
        let sentinelContents = Data("#EXTM3U\noutside.flac\n".utf8)
        try sentinelContents.write(to: sentinel)
        try FileManager.default.removeItem(
            at: scenario.fileSystem.displayURL(for: scenario.playlistPath)
        )
        try FileManager.default.createSymbolicLink(
            at: scenario.fileSystem.displayURL(for: scenario.playlistPath),
            withDestinationURL: sentinel
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryPruner(scanner: QobuzArchiveScanner()).pruneProblems(
                at: fixture.source,
                snapshot: scenario.snapshot
            )
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelContents)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent(fixture.audioPath).path
        ))
    }
}

private struct LibraryPrunePlaylistScenario {
    let fileSystem: LibraryFileSystem
    let playlistPath: LibraryRelativePath
    let snapshot: QobuzArchiveSnapshot
}

private extension LibraryMaintenanceFixture {
    func writePlaylistWithDuplicateProblem() async throws -> LibraryPrunePlaylistScenario {
        _ = try await writeTwoTrackLibraryWithFirstProblem()
        let fileSystem = try LibraryFileSystem(rootURL: source)
        let title = "Prune Mix"
        let qobuzID = "playlist"
        let folderName = QobuzPlaylistFolderPlanner(
            outputPlanner: StandardQobuzOutputPlanner()
        ).folderName(title: title, id: QobuzID(qobuzID))
        let folder = try LibraryRelativePath("Playlists").appending(folderName)
        let playlistPath = try folder.appending(
            QobuzManagedLibraryAssetPolicy.playlistFilename(
                title: title,
                outputPlanner: StandardQobuzOutputPlanner()
            )
        )
        let trackPaths = [audioPath, audioPath, secondAudioPath]
        var manifest = try QobuzLibraryManifestIO.load(in: fileSystem)
        manifest.collections.append(QobuzLibraryRecordFactory.playlist(
            qobuzID: qobuzID,
            title: title,
            owner: "Tester",
            relativePath: folder.rawValue,
            trackPaths: trackPaths
        ))
        try QobuzLibraryManifestIO.save(manifest, in: fileSystem)
        let entries = [
            QobuzM3UPlaylist.Entry(
                path: "../../\(audioPath)",
                extendedInfo: "#EXTINF:101,Removed - First occurrence"
            ),
            QobuzM3UPlaylist.Entry(
                path: "../../\(audioPath)",
                extendedInfo: "#EXTINF:101,Removed - Second occurrence"
            ),
            QobuzM3UPlaylist.Entry(
                path: "../../\(secondAudioPath)",
                extendedInfo: "#EXTINF:202,Keeper - Retained presentation"
            )
        ]
        try fileSystem.writeAtomically(
            Data(QobuzM3UPlaylist.contents(for: entries).utf8),
            to: playlistPath
        )
        return LibraryPrunePlaylistScenario(
            fileSystem: fileSystem,
            playlistPath: playlistPath,
            snapshot: try await QobuzArchiveScanner().scan(root: source)
        )
    }
}

private enum PlaylistPruneFailure: Error {
    case stop
}
