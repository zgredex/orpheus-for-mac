import Foundation
import NativeQobuzCore
import XCTest
@testable import OrpheusNative

@MainActor
final class NativeLoggingTests: XCTestCase {
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

    func testDiagnosticExportContainsReportAndNeverContainsCredentialValues() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let store = NativeLogFileStore(paths: paths)
        let viewModel = NativeViewModel(
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: FileCredentialStore(paths: paths),
            archiveStore: NativeArchiveIndexStore(paths: paths),
            sessionStore: NativeSessionStore(paths: paths),
            logStore: store
        )
        qobuzLog.warning(
            "test.security",
            "auth_token=DO-NOT-EXPORT-THIS",
            metadata: ["appSecret": "ALSO-SECRET", "safeValue": "visible"]
        )

        let exportParent = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let bundle = try viewModel.exportDiagnostics(to: exportParent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("system-info.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("README.txt").path))

        let text = try diagnosticBundleText(at: bundle)
        XCTAssertFalse(text.contains("DO-NOT-EXPORT-THIS"))
        XCTAssertFalse(text.contains("ALSO-SECRET"))
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains("credentialsConfigured"))
        XCTAssertTrue(text.contains("Credentials and authentication values are intentionally excluded"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OrpheusDiagnostics-\(UUID().uuidString)", isDirectory: true)
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
