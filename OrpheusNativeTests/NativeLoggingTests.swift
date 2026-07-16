import Foundation
import NativeQobuzCore
import XCTest
@testable import OrpheusNative

@MainActor
final class NativeLoggingTests: XCTestCase {
    func testLogStoreMulticastsToIndependentSubscribers() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeLogFileStore(paths: paths)
        try store.activate()
        let first = store.entryStream()
        let second = store.entryStream()
        let firstReceived = expectation(description: "first subscriber")
        let secondReceived = expectation(description: "second subscriber")
        let entry = logEntry(level: .info, message: "multicast")

        Task {
            for await value in first where value.id == entry.id {
                firstReceived.fulfill()
                break
            }
        }
        Task {
            for await value in second where value.id == entry.id {
                secondReceived.fulfill()
                break
            }
        }
        store.append(entry)

        await fulfillment(of: [firstReceived, secondReceived], timeout: 1)
    }

    func testErrorEntryFlushesImmediatelyWithoutAReadBarrier() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeLogFileStore(paths: paths)
        try store.activate()
        let entry = logEntry(level: .error, message: "durable immediately")
        store.append(entry)
        let current = paths.logsDirectory.appendingPathComponent("orpheus-current.jsonl")

        var persisted = false
        for _ in 0..<50 where !persisted {
            try await Task.sleep(for: .milliseconds(10))
            let data = (try? Data(contentsOf: current)) ?? Data()
            persisted = String(decoding: data, as: UTF8.self).contains(entry.id.uuidString)
        }
        XCTAssertTrue(persisted)
    }

    func testTailReaderReturnsOnlyNewestRecordsAcrossArchives() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let codec = NativeLogCodec()
        let archive = root.appendingPathComponent("orpheus-archive.jsonl")
        let current = root.appendingPathComponent("orpheus-current.jsonl")
        var olderData = Data()
        for index in 0..<500 {
            olderData.append(try codec.encodeLine(logEntry(level: .info, message: "old-\(index)")))
        }
        try olderData.write(to: archive)
        var currentData = Data()
        for index in 0..<10 {
            currentData.append(try codec.encodeLine(logEntry(level: .info, message: "new-\(index)")))
        }
        try currentData.write(to: current)

        let entries = try NativeLogTailReader(codec: codec).loadEntries(
            files: [archive, current],
            limit: 3
        )

        XCTAssertEqual(entries.map(\.message), ["new-7", "new-8", "new-9"])
    }

    func testLogStorePersistsRotatesAndClearsStructuredEntries() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeLogFileStore(
            paths: paths,
            maximumFileBytes: 700,
            maximumArchives: 2
        )
        try store.activate()

        for index in 0..<20 {
            qobuzLog.info(
                "test.rotation",
                "Persisted event \(index) " + String(repeating: "x", count: 180),
                metadata: ["sequence": String(index)]
            )
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: paths.logsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
        XCTAssertLessThanOrEqual(files.count, 3)
        let entries = try store.loadEntries(limit: 100)
        XCTAssertTrue(entries.contains { $0.category == "test.rotation" && $0.metadata["sequence"] == "19" })
        XCTAssertTrue(entries.allSatisfy { !$0.sourceFile.isEmpty && $0.sourceLine > 0 })

        try store.clear()
        let afterClear = try store.loadEntries(limit: 100)
        XCTAssertEqual(afterClear.last?.message, "Diagnostic history cleared by user")
        XCTAssertFalse(afterClear.contains { $0.category == "test.rotation" })
    }

    func testDiagnosticExportContainsReportAndNeverContainsCredentialValues() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeLogFileStore(paths: paths)
        let viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: FileCredentialStore(paths: paths),
            archiveStore: NativeArchiveIndexStore(paths: paths),
            sessionStore: NativeSessionStore(paths: paths),
            logStore: store,
            supplementalDiagnosticsCollector: StubSupplementalDiagnosticsCollector()
        )
        qobuzLog.warning(
            "test.security",
            "auth_token=DO-NOT-EXPORT-THIS",
            metadata: ["appSecret": "ALSO-SECRET", "safeValue": "visible"]
        )

        let exportParent = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let bundle = try await viewModel.exportDiagnostics(to: exportParent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("system-info.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("README.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("collection-status.json").path))

        let text = try diagnosticBundleText(at: bundle)
        XCTAssertFalse(text.contains("DO-NOT-EXPORT-THIS"))
        XCTAssertFalse(text.contains("ALSO-SECRET"))
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains("credentialsConfigured"))
        XCTAssertTrue(text.contains("Credentials and authentication values are intentionally excluded"))
        XCTAssertTrue(text.contains("systemWideUnifiedLogIncluded"))
        XCTAssertTrue(text.contains("never the privileged system-wide log"))
    }

    func testCrashReportExportMatchesAppLimitsAgeAndRedactsCredentials() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        let destination = root.appendingPathComponent("ExportedCrashReports", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let latest = source.appendingPathComponent("renamed-report.ips")
        try Data(
            #"{"bundleID":"com.orpheus.formac","auth_token":"LATEST-SECRET","marker":"latest"}"#.utf8
        ).write(to: latest)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: latest.path)

        let older = source.appendingPathComponent("OrpheusNative_older.crash")
        try Data("OrpheusNative older auth_token=OLDER-SECRET marker=older".utf8).write(to: older)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: older.path
        )

        let expired = source.appendingPathComponent("OrpheusNative_expired.ips")
        try Data("OrpheusNative marker=expired".utf8).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-40 * 24 * 60 * 60)],
            ofItemAtPath: expired.path
        )

        let unrelated = source.appendingPathComponent("AnotherApp.ips")
        try Data(#"{"bundleID":"com.example.other","marker":"unrelated"}"#.utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: unrelated.path)

        let exporter = NativeCrashReportExporter(
            sourceDirectories: [source],
            bundleIdentifier: "com.orpheus.formac",
            maximumReports: 1,
            now: { now }
        )
        let outcome = try exporter.export(to: destination)

        XCTAssertEqual(outcome.itemCount, 1)
        XCTAssertTrue(outcome.messages.contains { $0.contains("limited to the newest 1") })
        let exportedText = try diagnosticBundleText(at: destination)
        XCTAssertTrue(exportedText.contains("latest"))
        XCTAssertTrue(exportedText.contains("<redacted>"))
        XCTAssertFalse(exportedText.contains("LATEST-SECRET"))
        XCTAssertFalse(exportedText.contains("OLDER-SECRET"))
        XCTAssertFalse(exportedText.contains("marker=older"))
        XCTAssertFalse(exportedText.contains("marker=expired"))
        XCTAssertFalse(exportedText.contains("unrelated"))

        let exportedFiles = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        )
        let exportedData = try XCTUnwrap(exportedFiles.first.map { try Data(contentsOf: $0) })
        let exportedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exportedData) as? [String: String]
        )
        XCTAssertEqual(exportedJSON["auth_token"], "<redacted>")
        XCTAssertEqual(exportedJSON["marker"], "latest")
    }

    func testCurrentProcessUnifiedLogExportNeedsNoPrivilegedSystemStore() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("unified-log.jsonl")
        let exporter = NativeUnifiedLogExporter(
            maximumEntries: 100,
            sessionStartedAt: { .distantPast }
        )

        let outcome = try exporter.export(to: destination)

        XCTAssertLessThanOrEqual(outcome.itemCount, 100)
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: destination.path),
            outcome.itemCount > 0
        )
    }

    func testSupplementalCollectionGracefullyRecordsUnavailableSources() {
        let collector = NativeSupplementalDiagnosticsCollector(
            unifiedLogExporter: FailingUnifiedLogExporter(),
            crashReportExporter: EmptyCrashReportExporter()
        )

        let summary = collector.collect(into: temporaryRoot())

        XCTAssertEqual(summary.currentProcessUnifiedLog.state, .unavailable)
        XCTAssertEqual(summary.currentProcessUnifiedLog.itemCount, 0)
        XCTAssertTrue(summary.currentProcessUnifiedLog.messages.contains { $0.contains("TestFailure") })
        XCTAssertEqual(summary.crashReports.state, .empty)
        XCTAssertEqual(summary.crashReports.itemCount, 0)
        XCTAssertFalse(summary.systemWideUnifiedLogIncluded)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusDiagnostics-\(UUID().uuidString)", isDirectory: true)
    }

    private func logEntry(level: QobuzLogLevel, message: String) -> QobuzLogEntry {
        QobuzLogEntry(
            sessionID: QobuzDiagnostics.shared.sessionID,
            level: level,
            category: "test.storage",
            message: message,
            sourceFile: #fileID,
            sourceFunction: #function,
            sourceLine: #line,
            thread: "test"
        )
    }

    private func diagnosticBundleText(at root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return ""
        }
        var result = ""
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result += String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return result
    }
}

private struct StubSupplementalDiagnosticsCollector: NativeSupplementalDiagnosticsCollecting {
    func collect(into bundleRoot: URL) -> NativeSupplementalDiagnosticSummary {
        NativeSupplementalDiagnosticSummary(
            generatedAt: Date(timeIntervalSince1970: 0),
            currentProcessUnifiedLog: NativeDiagnosticArtifactStatus(
                state: .empty,
                itemCount: 0,
                relativePath: nil,
                messages: []
            ),
            crashReports: NativeDiagnosticArtifactStatus(
                state: .empty,
                itemCount: 0,
                relativePath: nil,
                messages: []
            ),
            systemWideUnifiedLogIncluded: false
        )
    }
}

private struct FailingUnifiedLogExporter: NativeUnifiedLogExporting {
    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome {
        throw NSError(domain: "TestFailure", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Unified Log intentionally unavailable"
        ])
    }
}

private struct EmptyCrashReportExporter: NativeCrashReportExporting {
    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome {
        NativeDiagnosticArtifactOutcome(itemCount: 0)
    }
}
