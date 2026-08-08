import Foundation
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativePersistenceHardeningTests: XCTestCase {
    func testMalformedConfigurationIsQuarantinedAndReplacedWithFreshDefaults() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("not-json".utf8).write(to: fixture.paths.configurationURL)

        let configuration = try NativeConfigurationStore(paths: fixture.paths).load()

        XCTAssertEqual(configuration.settings.downloadPath, fixture.paths.defaultDownloadRoot.path)
        XCTAssertEqual(configuration.settings.quality, .hiRes)
        XCTAssertFalse(configuration.credentials.isComplete)
        XCTAssertEqual(
            try fixture.rejectedFiles(prefix: "configuration.rejected-").count,
            1
        )
        XCTAssertEqual(try NativeConfigurationStore(paths: fixture.paths).load(), configuration)
    }

    func testConfigurationSymlinkIsQuarantinedWithoutReadingOrChangingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("outside-configuration.json")
        try Data("outside private data".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.configurationURL,
            withDestinationURL: target
        )

        let configuration = try NativeConfigurationStore(paths: fixture.paths).load()
        XCTAssertFalse(configuration.credentials.isComplete)
        XCTAssertEqual(try Data(contentsOf: target), Data("outside private data".utf8))
        let rejected = try fixture.rejectedFiles(prefix: "configuration.rejected-")
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
