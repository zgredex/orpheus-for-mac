import Darwin
import XCTest
@testable import NativeQobuzCore

final class LibraryFileSystemTests: XCTestCase {
    func testAtomicWriteCreatesDirectoriesAndReplacesRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)
        let path = try LibraryRelativePath("Artist/Album/track.flac")

        try fileSystem.writeAtomically(Data("one".utf8), to: path)
        try fileSystem.writeAtomically(Data("two".utf8), to: path)

        XCTAssertEqual(try fileSystem.read(path), Data("two".utf8))
        XCTAssertEqual(try fileSystem.metadata(at: path)?.kind, .regularFile)
    }

    func testBoundedReadRejectsOversizedRegularFileBeforeReturningData() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)
        let path = try LibraryRelativePath("manifest.json")
        try fileSystem.writeAtomically(Data(repeating: 0x61, count: 17), to: path)

        XCTAssertThrowsError(try fileSystem.read(path, maximumBytes: 16)) {
            XCTAssertEqual(
                $0 as? LibraryFileSystemError,
                .tooLarge(path: path.rawValue, maximumBytes: 16, actualBytes: 17)
            )
        }
    }

    func testTruncatingHardLinkedPartialCannotModifyOutsideTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.outside.appendingPathComponent("outside.partial")
        let payload = Data("outside bytes must survive".utf8)
        try payload.write(to: outside)
        let partial = fixture.library.appendingPathComponent("track.flac.partial")
        let result = outside.path.withCString { source in
            partial.path.withCString { destination in Darwin.link(source, destination) }
        }
        XCTAssertEqual(result, 0)
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)
        let path = try LibraryRelativePath("track.flac.partial")

        XCTAssertEqual(try fileSystem.metadata(at: path)?.kind, .hardLink)
        XCTAssertThrowsError(try fileSystem.writableHandle(at: path, truncate: true)) {
            XCTAssertEqual($0 as? LibraryFileSystemError, .hardLink(path.rawValue))
        }
        XCTAssertEqual(try Data(contentsOf: outside), payload)
        XCTAssertEqual(try Data(contentsOf: partial), payload)
    }

    func testNamedPipeIsRejectedBeforeOpenCanBlock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pipe = fixture.library.appendingPathComponent("manifest.json")
        XCTAssertEqual(pipe.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }, 0)
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)
        let path = try LibraryRelativePath("manifest.json")

        XCTAssertThrowsError(try fileSystem.read(path)) {
            XCTAssertEqual($0 as? LibraryFileSystemError, .notRegularFile(path.rawValue))
        }
    }

    func testDescriptorRelativeMoveRejectsSymlinkWithoutReadingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.outside.appendingPathComponent("sentinel.json")
        try Data("outside".utf8).write(to: target)
        let source = fixture.library.appendingPathComponent("cache.json")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)

        XCTAssertThrowsError(
            try fileSystem.moveItem(
                at: LibraryRelativePath("cache.json"),
                to: LibraryRelativePath("cache.rejected.json")
            )
        ) {
            guard case LibraryFileSystemError.symbolicLink = $0 else {
                return XCTFail("Expected symbolic-link rejection, got \($0)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.library.appendingPathComponent("cache.rejected.json").path
        ))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: source.path
            ),
            target.path
        )
        XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
    }

    func testQuarantineRenamesSymlinkLeafWithoutOpeningItsTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.outside.appendingPathComponent("sentinel.json")
        try Data("outside".utf8).write(to: target)
        let source = fixture.library.appendingPathComponent("cache.json")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)

        try fileSystem.quarantineItem(
            at: LibraryRelativePath("cache.json"),
            to: LibraryRelativePath("cache.rejected.json")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.library.appendingPathComponent("cache.rejected.json").path
            ),
            target.path
        )
        XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
    }

    func testDirectoryEnumerationUsesAnIndependentCursorEveryTime() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)
        try fileSystem.writeAtomically(
            Data("one".utf8),
            to: LibraryRelativePath("first.json")
        )
        try fileSystem.writeAtomically(
            Data("two".utf8),
            to: LibraryRelativePath("second.json")
        )

        let first = try fileSystem.entries(in: .root)
        let second = try fileSystem.entries(in: .root)

        XCTAssertEqual(first.map(\.path), second.map(\.path))
        XCTAssertEqual(second.count, 2)
    }

    func testConfiguredRootRejectsSymlinkInAnyAbsolutePathComponent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let realRoot = fixture.outside.appendingPathComponent("RealLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let linkedParent = fixture.root.appendingPathComponent("LinkedLibrary", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realRoot)

        XCTAssertThrowsError(
            try LibraryFileSystem(rootURL: linkedParent.appendingPathComponent("Nested"))
        ) {
            guard case LibraryFileSystemError.symbolicLink = $0 else {
                return XCTFail("Expected ancestor symbolic-link rejection, got \($0)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: realRoot.appendingPathComponent("Nested").path)
        )
    }

    func testArtistDirectorySymlinkIsRejectedWithoutTouchingTarget() throws {
        try assertDirectorySymlinkRejected(linkPath: "Artist", writePath: "Artist/Album/track.flac")
    }

    func testAlbumDirectorySymlinkIsRejectedWithoutTouchingTarget() throws {
        try assertDirectorySymlinkRejected(linkPath: "Artist/Album", writePath: "Artist/Album/track.flac")
    }

    func testAudioFileSymlinkIsRejectedWithoutTouchingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.library.appendingPathComponent("Artist/Album"),
            withIntermediateDirectories: true
        )
        let target = fixture.outside.appendingPathComponent("sentinel.flac")
        try Data("outside".utf8).write(to: target)
        let link = fixture.library.appendingPathComponent("Artist/Album/track.flac")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)
        let path = try LibraryRelativePath("Artist/Album/track.flac")

        XCTAssertThrowsError(try fileSystem.writeAtomically(Data("replacement".utf8), to: path)) {
            guard case LibraryFileSystemError.symbolicLink = $0 else {
                return XCTFail("Expected symbolic-link rejection, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
    }

    func testRecursiveEnumerationReportsManifestSymlinkWithoutOpeningTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.outside.appendingPathComponent("secret.json")
        try Data("not a manifest".utf8).write(to: target)
        let album = fixture.library.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let link = album.appendingPathComponent(QobuzProvenanceManifestIO.filename)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)

        let snapshot = try fileSystem.recursiveSnapshot()

        XCTAssertEqual(
            snapshot.entries.first { $0.path.rawValue.hasSuffix(QobuzProvenanceManifestIO.filename) }?.metadata.kind,
            .symbolicLink
        )
        XCTAssertEqual(snapshot.issues.map(\.path.rawValue), ["Artist/Album/.orpheus-provenance.json"])
        XCTAssertEqual(try Data(contentsOf: target), Data("not a manifest".utf8))
    }

    func testUnsafeRelativePathsAreRejectedBeforeIO() throws {
        XCTAssertThrowsError(try LibraryRelativePath("../outside"))
        XCTAssertThrowsError(try LibraryRelativePath("/absolute"))
        XCTAssertThrowsError(try LibraryRelativePath("Artist//Album"))
    }

    private func assertDirectorySymlinkRejected(linkPath: String, writePath: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = (linkPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                at: fixture.library.appendingPathComponent(parent),
                withIntermediateDirectories: true
            )
        }
        let sentinel = fixture.outside.appendingPathComponent("sentinel.txt")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: fixture.library.appendingPathComponent(linkPath),
            withDestinationURL: fixture.outside
        )
        let fileSystem = try LibraryFileSystem(rootURL: fixture.library)

        XCTAssertThrowsError(
            try fileSystem.writeAtomically(Data("replacement".utf8), to: LibraryRelativePath(writePath))
        ) {
            guard case LibraryFileSystemError.symbolicLink = $0 else {
                return XCTFail("Expected symbolic-link rejection, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("Album/track.flac").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("track.flac").path))
    }
}

private struct Fixture {
    let root: URL
    let library: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
