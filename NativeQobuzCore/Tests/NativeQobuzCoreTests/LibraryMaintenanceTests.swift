import XCTest
@testable import NativeQobuzCore

final class LibraryMaintenanceTests: XCTestCase {
    func testRelocationCopiesOnlyManagedAssetsAndVerifiesTheNewIndex() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let unrelated = fixture.source.appendingPathComponent("notes.txt")
        try Data("personal".utf8).write(to: unrelated)

        let result = try await QobuzLibraryMaintenanceService().relocate(
            from: fixture.source,
            to: fixture.destination,
            snapshot: snapshot
        )

        XCTAssertEqual(result.snapshot.verifiedCount, 1)
        XCTAssertEqual(result.snapshot.problemCount, 0)
        XCTAssertEqual(result.snapshot.collections, snapshot.collections)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent(fixture.audioPath).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("Artist/Album/cover.jpg").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("notes.txt").path
        ))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("personal".utf8))
    }

    func testRelocationCopiesStandaloneTrackArtworkAndBooklet() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedStandaloneTrackLibrary()

        let result = try await QobuzLibraryMaintenanceService().relocate(
            from: fixture.source,
            to: fixture.destination,
            snapshot: snapshot
        )

        XCTAssertEqual(result.snapshot.verifiedCount, 1)
        XCTAssertEqual(result.snapshot.collections.first?.kind, .track)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("Artist/Album/cover.jpg").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("Artist/Album/Booklet.pdf").path
        ))
    }

    func testRelocationRejectsNonemptyDestinationWithoutChangingIt() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let sentinel = fixture.destination.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryMaintenanceService().relocate(
                from: fixture.source,
                to: fixture.destination,
                snapshot: snapshot
            )
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testRelocationRejectsAudioSymlinkWithoutReadingOrCopyingTarget() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let audio = fixture.source.appendingPathComponent(fixture.audioPath)
        try FileManager.default.removeItem(at: audio)
        let secret = fixture.outside.appendingPathComponent("secret.flac")
        try Data("outside".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: secret)

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryMaintenanceService().relocate(
                from: fixture.source,
                to: fixture.destination,
                snapshot: snapshot
            )
        }

        XCTAssertEqual(try Data(contentsOf: secret), Data("outside".utf8))
        XCTAssertTrue(try LibraryFileSystem(rootURL: fixture.destination).entries(in: .root).isEmpty)
    }

    func testRelocationFirstCopyFailureRemovesCreatedDirectoriesAndAllowsRetry() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let failing = QobuzLibraryRelocator(
            scanner: QobuzArchiveScanner(),
            copier: LibraryFileCopier(afterDestinationOpen: { path in
                if !path.ancestorDirectories.isEmpty {
                    throw InjectedMaintenanceFailure.stop
                }
            })
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await failing.relocate(
                from: fixture.source,
                to: fixture.destination,
                snapshot: snapshot
            )
        }

        let destination = try LibraryFileSystem(rootURL: fixture.destination)
        XCTAssertTrue(try destination.entries(in: .root).isEmpty)
        let retried = try await QobuzLibraryMaintenanceService().relocate(
            from: fixture.source,
            to: fixture.destination,
            snapshot: snapshot
        )
        XCTAssertEqual(retried.snapshot.problemCount, 0)
        XCTAssertEqual(retried.snapshot.verifiedCount, snapshot.verifiedCount)
    }

    func testPruneRemovesProblematicTrackAndReconcilesManifests() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.writeVerifiedLibrary()
        let audio = fixture.source.appendingPathComponent(fixture.audioPath)
        try Data("changed".utf8).write(to: audio)
        let snapshot = try await QobuzArchiveScanner().scan(root: fixture.source)
        let unrelated = fixture.source.appendingPathComponent("notes.txt")
        try Data("personal".utf8).write(to: unrelated)

        let result = try await QobuzLibraryMaintenanceService().pruneProblems(
            at: fixture.source,
            snapshot: snapshot
        )

        XCTAssertEqual(result.removedTrackCount, 1)
        XCTAssertTrue(result.snapshot.tracks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent("Artist/Album/.orpheus-provenance.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent(".orpheus-library.json").path
        ))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("personal".utf8))
    }

    func testDeleteLibraryPreservesUnrelatedFilesAndFolder() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let unrelated = fixture.source.appendingPathComponent("personal-document.txt")
        try Data("keep".utf8).write(to: unrelated)

        let result = try await QobuzLibraryMaintenanceService().deleteLibrary(
            at: fixture.source,
            snapshot: snapshot
        )

        XCTAssertTrue(result.snapshot.tracks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent(fixture.audioPath).path
        ))
    }

    func testDeleteLibraryRejectsStaleSnapshotBeforeChangingFiles() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let audio = fixture.source.appendingPathComponent(fixture.audioPath)
        let changed = Data("changed after scan".utf8)
        try changed.write(to: audio)

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryMaintenanceService().deleteLibrary(
                at: fixture.source,
                snapshot: snapshot
            )
        }

        XCTAssertEqual(try Data(contentsOf: audio), changed)
    }

    func testDeleteLibraryPreservesUnownedFilesInsideCollectionFolder() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let folder = fixture.source.appendingPathComponent("Artist/Album")
        let personalPlaylist = folder.appendingPathComponent("personal.m3u")
        let alternateArtwork = folder.appendingPathComponent("cover.png")
        try Data("#EXTM3U\npersonal.flac\n".utf8).write(to: personalPlaylist)
        try Data("personal artwork".utf8).write(to: alternateArtwork)

        _ = try await QobuzLibraryMaintenanceService().deleteLibrary(
            at: fixture.source,
            snapshot: snapshot
        )

        XCTAssertEqual(try Data(contentsOf: personalPlaylist), Data("#EXTM3U\npersonal.flac\n".utf8))
        XCTAssertEqual(try Data(contentsOf: alternateArtwork), Data("personal artwork".utf8))
    }

    func testDeleteStandaloneTrackRemovesOwnedArtworkAndBooklet() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedStandaloneTrackLibrary()
        let cover = fixture.source.appendingPathComponent("Artist/Album/cover.jpg")
        let booklet = fixture.source.appendingPathComponent("Artist/Album/Booklet.pdf")

        _ = try await QobuzLibraryMaintenanceService().deleteLibrary(
            at: fixture.source,
            snapshot: snapshot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: booklet.path))
    }

    func testDeleteRejectsAudioSymlinkWithoutTouchingItsTarget() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let audio = fixture.source.appendingPathComponent(fixture.audioPath)
        try FileManager.default.removeItem(at: audio)
        let sentinel = fixture.outside.appendingPathComponent("sentinel.flac")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: sentinel)

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryMaintenanceService().deleteLibrary(
                at: fixture.source,
                snapshot: snapshot
            )
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside".utf8))
    }

    func testDeleteRejectsManagedSidecarSymlinkBeforeRemovingAudio() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let audio = fixture.source.appendingPathComponent(fixture.audioPath)
        let sidecar = fixture.source.appendingPathComponent("Artist/Album/description.txt")
        try FileManager.default.removeItem(at: sidecar)
        let sentinel = fixture.outside.appendingPathComponent("sentinel.txt")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: sentinel)

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryMaintenanceService().deleteLibrary(
                at: fixture.source,
                snapshot: snapshot
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside".utf8))
    }

    func testPruneRollsBackAudioAndManifestReplacementsWhenIndexingFails() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeTwoTrackLibraryWithFirstProblem()
        let managedPaths = fixture.twoTrackManagedPaths
        let before = try fixture.contents(at: managedPaths)
        let unrelated = fixture.source.appendingPathComponent("Artist/Album/personal.txt")
        try Data("keep".utf8).write(to: unrelated)

        let failingScanners: [any QobuzArchiveScanning] = [
            FailingMaintenanceScanner(),
            FixedMaintenanceScanner(snapshot: snapshot)
        ]
        for scanner in failingScanners {
            await XCTAssertThrowsErrorAsync {
                _ = try await QobuzLibraryPruner(scanner: scanner).pruneProblems(
                    at: fixture.source,
                    snapshot: snapshot
                )
            }
            XCTAssertEqual(try fixture.contents(at: managedPaths), before)
            XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
        }

        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testPruneRollsBackWhenFailureOccursAfterApplyingManifestChanges() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeTwoTrackLibraryWithFirstProblem()
        let managedPaths = fixture.twoTrackManagedPaths
        let before = try fixture.contents(at: managedPaths)

        let pruner = QobuzLibraryPruner(
            scanner: QobuzArchiveScanner(),
            faultInjector: { checkpoint in
                if case .appliedFinalState = checkpoint { throw InjectedMaintenanceFailure.stop }
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await pruner.pruneProblems(at: fixture.source, snapshot: snapshot)
        }

        XCTAssertEqual(try fixture.contents(at: managedPaths), before)
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testDeleteFailsClosedOnSymlinkedRecoveryQuarantine() async throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let snapshot = try await fixture.writeVerifiedLibrary()
        let sentinel = fixture.outside.appendingPathComponent("sentinel.txt")
        try Data("outside".utf8).write(to: sentinel)
        let quarantine = fixture.source.appendingPathComponent(
            LibraryFileTransactionJournal.directoryPrefix + UUID().uuidString.lowercased()
        )
        try FileManager.default.createSymbolicLink(at: quarantine, withDestinationURL: fixture.outside)

        await XCTAssertThrowsErrorAsync {
            _ = try await QobuzLibraryMaintenanceService().deleteLibrary(
                at: fixture.source,
                snapshot: snapshot
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent(fixture.audioPath).path
        ))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside".utf8))
    }

    func testInterruptedStagingJournalRestoresQuarantinedOriginal() throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let contents = Data("preserve after crash".utf8)
        let interrupted = try fixture.interruptedPruneTransaction(
            originalPath: "Artist/Album/original.flac",
            contents: contents,
            phase: "staging"
        )

        try QobuzLibraryMutationRecovery.recover(at: fixture.source)

        XCTAssertEqual(try interrupted.fileSystem.read(interrupted.original), contents)
        XCTAssertNil(try interrupted.fileSystem.metadata(at: interrupted.directory))
    }

    func testInterruptedCommittedJournalFinishesQuarantineCleanup() throws {
        let fixture = try LibraryMaintenanceFixture()
        defer { fixture.cleanup() }
        let interrupted = try fixture.interruptedPruneTransaction(
            originalPath: "Artist/Album/committed.flac",
            contents: Data("already committed".utf8),
            phase: "committing"
        )

        try QobuzLibraryMutationRecovery.recover(at: fixture.source)

        XCTAssertNil(try interrupted.fileSystem.metadata(at: interrupted.original))
        XCTAssertNil(try interrupted.fileSystem.metadata(at: interrupted.directory))
    }
}

struct LibraryMaintenanceFixture {
    let root: URL
    let source: URL
    let destination: URL
    let outside: URL
    let audioPath = "Artist/Album/01. Track.flac"
    let secondAudioPath = "Artist/Album/02. Second.flac"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        outside = root.appendingPathComponent("Outside", isDirectory: true)
        for directory in [source, destination, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func writeVerifiedLibrary() async throws -> QobuzArchiveSnapshot {
        try await writeVerifiedLibrary(kind: .album)
    }

    func writeVerifiedStandaloneTrackLibrary() async throws -> QobuzArchiveSnapshot {
        try await writeVerifiedLibrary(kind: .track)
    }

    func writeTwoTrackLibraryWithFirstProblem() async throws -> QobuzArchiveSnapshot {
        _ = try await writeLibrary(
            kind: .album,
            tracks: [
                (path: audioPath, id: "track-1", data: Data("audio one".utf8)),
                (path: secondAudioPath, id: "track-2", data: Data("audio two".utf8))
            ]
        )
        try Data("changed after verification".utf8).write(
            to: source.appendingPathComponent(audioPath)
        )
        return try await QobuzArchiveScanner().scan(root: source)
    }

    var twoTrackManagedPaths: [String] {
        [
            audioPath,
            secondAudioPath,
            "Artist/Album/.orpheus-provenance.json",
            "Artist/Album/checksums.sha256",
            "Artist/Album/cover.jpg",
            "Artist/Album/description.txt",
            ".orpheus-library.json"
        ]
    }

    func contents(at relativePaths: [String]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: relativePaths.map { path in
            (path, try Data(contentsOf: source.appendingPathComponent(path)))
        })
    }

    func transactionDirectories() throws -> [LibraryDirectoryEntry] {
        try LibraryFileSystem(rootURL: source, createIfMissing: false).entries(in: .root).filter {
            $0.path.lastComponent?.hasPrefix(LibraryFileTransactionJournal.directoryPrefix) == true
        }
    }

    func interruptedPruneTransaction(
        originalPath: String,
        contents: Data,
        phase: String
    ) throws -> (
        fileSystem: LibraryFileSystem,
        original: LibraryRelativePath,
        directory: LibraryRelativePath
    ) {
        let fileSystem = try LibraryFileSystem(rootURL: source)
        let original = try LibraryRelativePath(originalPath)
        try fileSystem.writeAtomically(contents, to: original)
        let directory = try LibraryRelativePath(
            LibraryFileTransactionJournal.directoryPrefix + UUID().uuidString.lowercased()
        )
        let staged = try directory.appending("00000000.original")
        try fileSystem.createDirectory(directory)
        try fileSystem.moveItem(at: original, to: staged)
        let journal = LibraryFileTransactionJournal(
            version: 1,
            operation: "library-prune",
            directory: directory,
            phase: try XCTUnwrap(LibraryFileTransactionJournal.Phase(rawValue: phase)),
            entries: [
                LibraryFileTransactionJournal.Entry(
                    originalPath: original.rawValue,
                    quarantinedPath: staged.rawValue,
                    originalSHA256: MusicFileIntegrity.sha256(of: contents),
                    finalSHA256: nil,
                    replacementSourcePath: nil
                )
            ]
        )
        try fileSystem.writeAtomically(
            try JSONEncoder().encode(journal),
            to: directory.appending(LibraryFileTransactionJournal.filename)
        )
        return (fileSystem, original, directory)
    }

    private func writeVerifiedLibrary(kind: QobuzArchiveKind) async throws -> QobuzArchiveSnapshot {
        try await writeLibrary(
            kind: kind,
            tracks: [(path: audioPath, id: "track", data: Data("audio".utf8))]
        )
    }

    private func writeLibrary(
        kind: QobuzArchiveKind,
        tracks: [(path: String, id: String, data: Data)]
    ) async throws -> QobuzArchiveSnapshot {
        let fileSystem = try LibraryFileSystem(rootURL: source)
        var provenanceFiles: [String: [String: Any]] = [:]
        var checksums: [String: String] = [:]
        var audioPaths: [LibraryRelativePath] = []
        for track in tracks {
            let audio = try LibraryRelativePath(track.path)
            try fileSystem.writeAtomically(track.data, to: audio)
            let checksum = try MusicFileIntegrity.sha256(of: audio, in: fileSystem)
            let leaf = try XCTUnwrap(audio.lastComponent)
            provenanceFiles[leaf] = [
                "qobuzTrackID": track.id,
                "qobuzAlbumID": "album",
                "formatID": 27,
                "bitDepth": 24,
                "samplingRate": 96,
                "sha256": checksum,
                "archiveKind": kind.rawValue,
                "isLibraryManaged": true
            ]
            checksums[leaf] = checksum
            audioPaths.append(audio)
        }
        let provenance = [
            "version": 1,
            "files": provenanceFiles
        ] as [String: Any]
        let folder = try XCTUnwrap(audioPaths.first).parent
        try fileSystem.writeAtomically(
            try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys]),
            to: folder.appending(QobuzProvenanceManifestIO.filename)
        )
        try fileSystem.writeAtomically(
            QobuzChecksumManifest.encode(checksums),
            to: folder.appending(QobuzChecksumManifest.filename)
        )
        try fileSystem.writeAtomically(
            Data("cover".utf8),
            to: folder.appending("cover.jpg")
        )
        let sidecar = kind == .track ? "Booklet.pdf" : "description.txt"
        try fileSystem.writeAtomically(Data("sidecar".utf8), to: folder.appending(sidecar))
        let collection: QobuzLibraryCollectionRecord
        if kind == .track {
            let audio = try XCTUnwrap(audioPaths.first)
            collection = QobuzLibraryRecordFactory.track(
                qobuzID: tracks[0].id,
                title: "Track",
                artist: "Artist",
                relativePath: audio.rawValue,
                artworkRelativePath: "Artist/Album/cover.jpg"
            )
        } else {
            collection = QobuzLibraryRecordFactory.album(
                qobuzID: "album",
                title: "Album",
                artist: "Artist",
                relativePath: folder.rawValue,
                trackPaths: audioPaths.map(\.rawValue),
                artworkRelativePath: "Artist/Album/cover.jpg"
            )
        }
        try QobuzLibraryManifestIO.save(
            QobuzLibraryManifest(collections: [collection]),
            in: fileSystem
        )
        return try await QobuzArchiveScanner().scan(root: source)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum InjectedMaintenanceFailure: Error {
    case stop
}

private struct FailingMaintenanceScanner: QobuzArchiveScanning {
    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        throw InjectedMaintenanceFailure.stop
    }
}

private struct FixedMaintenanceScanner: QobuzArchiveScanning {
    let snapshot: QobuzArchiveSnapshot

    func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        snapshot
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
