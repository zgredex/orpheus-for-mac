import XCTest
@testable import OrpheusNative

final class NativeMigrationTests: XCTestCase {
    func testMigrationCopiesPreviewDataWithoutDeletingSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusMigration-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("OrpheusNativePreview", isDirectory: true)
        let destination = root.appendingPathComponent("Orpheus for Mac", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"downloadPath":"/Music/Existing","quality":"hifi"}"#.utf8)
            .write(to: source.appendingPathComponent("settings.json"))
        let credentials = source.appendingPathComponent("credentials.json")
        try Data(#"{"appID":"id","appSecret":"secret","authToken":"token"}"#.utf8)
            .write(to: credentials)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: credentials.path)

        try NativePreviewDataMigrator(
            sourceRoot: source,
            destinationRoot: destination
        ).migrateIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("settings.json").path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("settings.json")),
            try Data(contentsOf: source.appendingPathComponent("settings.json"))
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(NativePreviewDataMigrator.markerName).path
        ))
        XCTAssertEqual(try permissions(at: destination), 0o700)
        XCTAssertEqual(try permissions(at: destination.appendingPathComponent("credentials.json")), 0o600)
    }

    func testMigrationMergesOnlyMissingDataIntoExistingReleaseRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusMigration-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Preview", isDirectory: true)
        let destination = root.appendingPathComponent("Release", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("preview-settings".utf8).write(to: source.appendingPathComponent("settings.json"))
        try Data("preview-session".utf8).write(to: source.appendingPathComponent("download-session.json"))
        try Data("release-settings".utf8).write(to: destination.appendingPathComponent("settings.json"))

        let migrator = NativePreviewDataMigrator(sourceRoot: source, destinationRoot: destination)
        try migrator.migrateIfNeeded()
        try migrator.migrateIfNeeded()

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("settings.json"), encoding: .utf8),
            "release-settings"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("download-session.json"), encoding: .utf8),
            "preview-session"
        )
    }

    func testMigrationDoesNothingWithoutPreviewData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Release", isDirectory: true)

        try NativePreviewDataMigrator(
            sourceRoot: root.appendingPathComponent("Missing"),
            destinationRoot: destination
        ).migrateIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
