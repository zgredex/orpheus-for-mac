import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

final class NativeDiagnosticsExportTests: XCTestCase {
    func testFailedExportNeverLeavesAPartialOrFinalBundleVisible() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeDiagnosticsExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let controller = NativeDiagnosticsController(
            logStore: FailingCopyLogStore(directoryURL: parent.appendingPathComponent("SourceLogs")),
            supplementalCollector: StubSupplementalDiagnosticsCollector()
        )

        do {
            _ = try await controller.export(snapshot: diagnosticSnapshot, to: parent)
            XCTFail("Expected the log-copy failure to abort the export.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("intentional copy failure"))
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testCrashReportSymlinkIsSkippedWithoutReadingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeCrashSymlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Reports", isDirectory: true)
        let destination = root.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.ips")
        try Data(#"{"bundleID":"com.orpheus.formac","auth_token":"SECRET"}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("OrpheusNative.ips"),
            withDestinationURL: target
        )

        let outcome = try NativeCrashReportExporter(
            sourceDirectories: [source],
            bundleIdentifier: "com.orpheus.formac"
        ).export(to: destination)

        XCTAssertEqual(outcome.itemCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(String(decoding: try Data(contentsOf: target), as: UTF8.self).contains("SECRET"))
    }

    private var diagnosticSnapshot: NativeDiagnosticSnapshot {
        NativeDiagnosticSnapshot(
            downloadQuality: "hiRes",
            downloadRoot: "/tmp/Music",
            queue: [],
            activities: [],
            libraryTrackCount: 0,
            libraryIssueCount: 0,
            credentialsConfigured: false
        )
    }
}

private struct FailingCopyLogStore: NativeLogStoring {
    let directoryURL: URL

    func activate() throws {}
    func append(_ entry: QobuzLogEntry) {}
    func loadEntries(limit: Int) throws -> [QobuzLogEntry] { [] }
    func entryStream() -> AsyncStream<QobuzLogEntry> { AsyncStream { $0.finish() } }
    func flush() throws {}
    func copyLogFiles(to destination: URL) throws {
        throw NSError(
            domain: "NativeDiagnosticsExportTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "intentional copy failure"]
        )
    }
    func clear() throws {}
}
