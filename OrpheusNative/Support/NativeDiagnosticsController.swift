import AppKit
import Foundation
import NativeQobuzCore

final class NativeDiagnosticsController: @unchecked Sendable {
    private let logStore: any NativeLogStoring
    private let supplementalCollector: any NativeSupplementalDiagnosticsCollecting

    init(
        logStore: any NativeLogStoring,
        supplementalCollector: any NativeSupplementalDiagnosticsCollecting
    ) {
        self.logStore = logStore
        self.supplementalCollector = supplementalCollector
    }

    var directoryURL: URL { logStore.directoryURL }

    func activate() throws {
        try logStore.activate()
    }

    func entries(limit: Int) throws -> [QobuzLogEntry] {
        try logStore.loadEntries(limit: limit)
    }

    func clear() throws {
        try logStore.clear()
    }

    func reveal() {
        qobuzLog.info("ui", "Reveal diagnostics folder requested")
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    func export(report: NativeDiagnosticReport, to parent: URL) async throws -> URL {
        let exportStartedAt = Date()
        qobuzLog.notice("diagnostics", "Diagnostic export started", metadata: ["destination": parent.path])
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .format(Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = parent.appendingPathComponent("Orpheus-Diagnostics-\(stamp)", isDirectory: true)
        let logs = destination.appendingPathComponent("Logs", isDirectory: true)
        let collector = supplementalCollector
        let persistentLogStore = logStore

        return try await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(
                    to: destination.appendingPathComponent("system-info.json"),
                    options: .atomic
                )
                let supplemental = collector.collect(into: destination)
                try encoder.encode(supplemental).write(
                    to: destination.appendingPathComponent("collection-status.json"),
                    options: .atomic
                )
                try Data(
                    """
                    Credentials and authentication values are intentionally excluded and redacted from this bundle.

                    Logs/ contains Orpheus's persistent structured JSONL diagnostics.
                    UnifiedLog/, when available, contains only this running Orpheus process and never the privileged system-wide log.
                    CrashReports/, when available, contains recent macOS reports matched to Orpheus and redacted for known authentication values.
                    collection-status.json records which optional artifacts were collected and why any source was unavailable.

                    Crash reports can contain local file paths and macOS system details. Review the bundle before sharing it publicly.
                    """.utf8
                ).write(to: destination.appendingPathComponent("README.txt"), options: .atomic)
                qobuzLog.notice(
                    "diagnostics",
                    "Diagnostic export artifacts assembled",
                    metadata: [
                        "unifiedLogStatus": supplemental.currentProcessUnifiedLog.state.rawValue,
                        "unifiedLogEntries": String(supplemental.currentProcessUnifiedLog.itemCount),
                        "crashReportStatus": supplemental.crashReports.state.rawValue,
                        "crashReports": String(supplemental.crashReports.itemCount)
                    ]
                )
                try persistentLogStore.copyLogFiles(to: logs)
                qobuzLog.notice(
                    "diagnostics",
                    "Diagnostic export completed",
                    metadata: [
                        "destination": destination.path,
                        "durationMs": String(Int(Date().timeIntervalSince(exportStartedAt) * 1_000))
                    ]
                )
                return destination
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                } catch {
                    qobuzLog.warning(
                        "diagnostics",
                        "Failed diagnostic export could not be removed",
                        metadata: ["destination": destination.path],
                        error: error
                    )
                }
                qobuzLog.error(
                    "diagnostics",
                    "Diagnostic export failed",
                    metadata: [
                        "destination": destination.path,
                        "durationMs": String(Int(Date().timeIntervalSince(exportStartedAt) * 1_000))
                    ],
                    error: error
                )
                throw error
            }
        }.value
    }
}
