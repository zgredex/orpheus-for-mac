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

    func testDiagnosticSnapshotTextIsRedactedBeforeExport() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeDiagnosticsRedaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let queueID = UUID()
        let snapshot = NativeDiagnosticSnapshot(
            downloadQuality: "auth_token=QUALITY-SECRET",
            downloadRoot: "/Music?app_secret=ROOT-SECRET",
            queue: [NativeDiagnosticQueueSummary(
                id: queueID,
                request: "album:1?request_sig=REQUEST-SECRET",
                title: "authorization: Bearer QUEUE-SECRET",
                status: "user_auth_token=STATUS-SECRET",
                selectedTracks: 1,
                quality: "app_secret=QUEUE-QUALITY-SECRET"
            )],
            activities: [NativeDiagnosticActivitySummary(
                id: UUID(),
                queueID: queueID,
                title: "auth_token=ACTIVITY-TITLE-SECRET",
                status: "authorization=ACTIVITY-STATUS-SECRET",
                phase: "request_sig=PHASE-SECRET",
                progress: 0.5,
                outputPath: "/Music?auth_token=PATH-SECRET",
                warnings: ["app_secret=WARNING-SECRET"],
                error: "Bearer ERROR-SECRET"
            )],
            libraryTrackCount: 1,
            libraryIssueCount: 1,
            credentialsConfigured: true
        )
        let controller = NativeDiagnosticsController(
            logStore: FixtureCopyLogStore(directoryURL: parent.appendingPathComponent("SourceLogs")),
            supplementalCollector: StubSupplementalDiagnosticsCollector()
        )

        let bundle = try await controller.export(snapshot: snapshot, to: parent)
        let report = String(
            decoding: try Data(contentsOf: bundle.appendingPathComponent("system-info.json")),
            as: UTF8.self
        )

        for secret in [
            "QUALITY-SECRET", "ROOT-SECRET", "REQUEST-SECRET", "QUEUE-SECRET",
            "STATUS-SECRET", "QUEUE-QUALITY-SECRET", "ACTIVITY-TITLE-SECRET",
            "ACTIVITY-STATUS-SECRET", "PHASE-SECRET", "PATH-SECRET",
            "WARNING-SECRET", "ERROR-SECRET"
        ] {
            XCTAssertFalse(report.contains(secret), "Export leaked \(secret)")
        }
        XCTAssertTrue(report.contains("<redacted>"))
    }

    func testExportedBundleUsesOwnerOnlyPermissionsForEveryItem() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeDiagnosticsPermissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let controller = NativeDiagnosticsController(
            logStore: FixtureCopyLogStore(directoryURL: parent.appendingPathComponent("SourceLogs")),
            supplementalCollector: InsecureFixtureSupplementalCollector()
        )

        let bundle = try await controller.export(snapshot: diagnosticSnapshot, to: parent)

        XCTAssertEqual(try permissions(at: bundle), 0o700)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ))
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                XCTAssertEqual(try permissions(at: url), 0o700, url.path)
            } else if values.isRegularFile == true {
                XCTAssertEqual(try permissions(at: url), 0o600, url.path)
            } else {
                XCTFail("Unexpected diagnostic bundle item: \(url.path)")
            }
        }
    }

    func testCrashReportIdentityRequiresExactStructuredValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeCrashIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Reports", isDirectory: true)
        let destination = root.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let reports: [(String, String)] = [
            ("OrpheusNative_false-positive.ips", #"{"bundleID":"com.example.other","marker":"filename"}"#),
            ("mention.ips", #"{"bundleID":"com.example.other","message":"com.orpheus.formac OrpheusNative","marker":"mention"}"#),
            ("helper.ips", #"{"bundleID":"com.orpheus.formac.helper","app_name":"OrpheusNative Helper","marker":"helper"}"#),
            ("renamed.ips", #"{"bundleID":"com.orpheus.formac","marker":"exact"}"#)
        ]
        for (name, contents) in reports {
            try Data(contents.utf8).write(to: source.appendingPathComponent(name))
        }

        let outcome = try NativeCrashReportExporter(
            sourceDirectories: [source],
            bundleIdentifier: "com.orpheus.formac",
            processNames: ["OrpheusNative"]
        ).export(to: destination)

        XCTAssertEqual(outcome.itemCount, 1)
        let text = try exportedText(at: destination)
        XCTAssertTrue(text.contains("exact"))
        XCTAssertFalse(text.contains("filename"))
        XCTAssertFalse(text.contains("mention"))
        XCTAssertFalse(text.contains("helper"))
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

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    private func exportedText(at root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return "" }
        var text = ""
        while let url = enumerator.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            text += String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return text
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

private struct FixtureCopyLogStore: NativeLogStoring {
    let directoryURL: URL

    func activate() throws {}
    func append(_ entry: QobuzLogEntry) {}
    func loadEntries(limit: Int) throws -> [QobuzLogEntry] { [] }
    func entryStream() -> AsyncStream<QobuzLogEntry> { AsyncStream { $0.finish() } }
    func flush() throws {}
    func copyLogFiles(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent("fixture.jsonl")
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: destination.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
    }
    func clear() throws {}
}

private struct InsecureFixtureSupplementalCollector: NativeSupplementalDiagnosticsCollecting {
    func collect(into bundleRoot: URL) -> NativeSupplementalDiagnosticSummary {
        let directory = bundleRoot.appendingPathComponent("CrashReports", isDirectory: true)
        let file = directory.appendingPathComponent("fixture.ips")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("fixture".utf8).write(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        return StubSupplementalDiagnosticsCollector().collect(into: bundleRoot)
    }
}
