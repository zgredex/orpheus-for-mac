import Foundation
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativePersistenceHardeningTests: XCTestCase {
    func testMalformedSettingsAreQuarantinedAndReplacedWithFreshDefaults() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("not-json".utf8).write(to: fixture.paths.settingsURL)

        let settings = try NativeSettingsStore(paths: fixture.paths).load()

        XCTAssertEqual(settings.downloadPath, fixture.paths.defaultDownloadRoot.path)
        XCTAssertEqual(settings.quality, .hiRes)
        XCTAssertEqual(
            try fixture.rejectedFiles(prefix: "settings.rejected-").count,
            1
        )
        XCTAssertEqual(try NativeSettingsStore(paths: fixture.paths).load(), settings)
    }

    func testCredentialSymlinkIsQuarantinedWithoutReadingOrChangingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("outside-credentials.json")
        try Data("outside private data".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.credentialsURL,
            withDestinationURL: target
        )

        XCTAssertNil(try FileCredentialStore(paths: fixture.paths).load())
        XCTAssertEqual(try Data(contentsOf: target), Data("outside private data".utf8))
        let rejected = try fixture.rejectedFiles(prefix: "credentials.rejected-")
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: rejected[0].path),
            target.path
        )
    }

    func testImportedLinkFileHasABoundedReadLimit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let imported = fixture.root.appendingPathComponent("links.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: imported.path, contents: nil))
        let handle = try FileHandle(forWritingTo: imported)
        try handle.truncate(atOffset: UInt64(2 * 1_024 * 1_024 + 1))
        try handle.close()
        let controller = NativeRequestIntakeController(linkInbox: NativeLinkInboxController())

        XCTAssertThrowsError(try controller.importedText(from: imported)) {
            XCTAssertTrue($0.localizedDescription.contains("safe limit"))
        }
    }
}

private struct Fixture {
    let root: URL
    let paths: NativePaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePersistenceHardening-\(UUID().uuidString)", isDirectory: true)
        paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        try FileManager.default.createDirectory(
            at: paths.applicationSupportRoot,
            withIntermediateDirectories: true
        )
    }

    func rejectedFiles(prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: paths.applicationSupportRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
