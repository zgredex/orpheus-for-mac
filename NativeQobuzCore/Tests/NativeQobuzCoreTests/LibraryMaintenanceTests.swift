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
}

private struct LibraryMaintenanceFixture {
    let root: URL
    let source: URL
    let destination: URL
    let outside: URL
    let audioPath = "Artist/Album/01. Track.flac"

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
        let fileSystem = try LibraryFileSystem(rootURL: source)
        let audio = try LibraryRelativePath(audioPath)
        try fileSystem.writeAtomically(Data("audio".utf8), to: audio)
        let checksum = try MusicFileIntegrity.sha256(of: audio, in: fileSystem)
        let provenance = [
            "version": 1,
            "files": [
                audio.lastComponent!: [
                    "qobuzTrackID": "track",
                    "qobuzAlbumID": "album",
                    "formatID": 27,
                    "bitDepth": 24,
                    "samplingRate": 96,
                    "sha256": checksum,
                    "archiveKind": "album",
                    "isLibraryManaged": true
                ] as [String: Any]
            ]
        ] as [String: Any]
        try fileSystem.writeAtomically(
            try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys]),
            to: audio.parent.appending(QobuzProvenanceManifestIO.filename)
        )
        try fileSystem.writeAtomically(
            QobuzChecksumManifest.encode([audio.lastComponent!: checksum]),
            to: audio.parent.appending(QobuzChecksumManifest.filename)
        )
        try fileSystem.writeAtomically(
            Data("cover".utf8),
            to: audio.parent.appending("cover.jpg")
        )
        try fileSystem.writeAtomically(
            Data("description".utf8),
            to: audio.parent.appending("description.txt")
        )
        try QobuzLibraryManifestIO.save(
            QobuzLibraryManifest(collections: [
                QobuzLibraryCollectionRecord(
                    id: "album|album",
                    kind: .album,
                    qobuzID: "album",
                    title: "Album",
                    subtitle: "Artist · 1 track",
                    relativePath: audio.parent.rawValue,
                    trackPaths: [audio.rawValue],
                    artworkRelativePath: "Artist/Album/cover.jpg"
                )
            ]),
            in: fileSystem
        )
        return try await QobuzArchiveScanner().scan(root: source)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
