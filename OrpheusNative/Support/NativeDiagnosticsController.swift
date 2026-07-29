import AppKit
import Foundation
import NativeQobuzCore

struct NativeDiagnosticSnapshot: Sendable {
    let downloadQuality: String
    let downloadRoot: String
    let queue: [NativeDiagnosticQueueSummary]
    let activities: [NativeDiagnosticActivitySummary]
    let libraryTrackCount: Int
    let libraryIssueCount: Int
    let credentialsConfigured: Bool
}

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

    func entryStream() -> AsyncStream<QobuzLogEntry> {
        logStore.entryStream()
    }

    func clear() throws {
        try logStore.clear()
    }

    func reveal() {
        qobuzLog.info("ui", "Reveal diagnostics folder requested")
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    func export(snapshot: NativeDiagnosticSnapshot, to parent: URL) async throws -> URL {
        let report = makeReport(from: snapshot)
        let exportStartedAt = Date()
        qobuzLog.notice("diagnostics", "Diagnostic export started", metadata: ["destination": parent.path])
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .format(Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = parent.appendingPathComponent("Orpheus-Diagnostics-\(stamp)", isDirectory: true)
        let staging = parent.appendingPathComponent(
            ".Orpheus-Diagnostics-\(UUID().uuidString).partial",
            isDirectory: true
        )
        let logs = staging.appendingPathComponent("Logs", isDirectory: true)
        let collector = supplementalCollector
        let persistentLogStore = logStore

        return try await Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(
                    to: staging.appendingPathComponent("system-info.json"),
                    options: .atomic
                )
                try Task.checkCancellation()
                let supplemental = collector.collect(into: staging)
                try encoder.encode(supplemental).write(
                    to: staging.appendingPathComponent("collection-status.json"),
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
                ).write(to: staging.appendingPathComponent("README.txt"), options: .atomic)
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
                try Task.checkCancellation()
                try persistentLogStore.copyLogFiles(to: logs)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staging, to: destination)
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
                    if FileManager.default.fileExists(atPath: staging.path) {
                        try FileManager.default.removeItem(at: staging)
                    }
                } catch {
                    qobuzLog.warning(
                        "diagnostics",
                        "Failed diagnostic export staging directory could not be removed",
                        metadata: ["stagingPath": staging.path],
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

    private func makeReport(from snapshot: NativeDiagnosticSnapshot) -> NativeDiagnosticReport {
        let bundle = Bundle.main
        return NativeDiagnosticReport(
            generatedAt: Date(),
            diagnosticSessionID: QobuzDiagnostics.shared.sessionID,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: NativeRuntimePlatform.architecture,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            downloadQuality: snapshot.downloadQuality,
            downloadRoot: snapshot.downloadRoot,
            queue: snapshot.queue,
            activities: snapshot.activities,
            libraryTrackCount: snapshot.libraryTrackCount,
            libraryIssueCount: snapshot.libraryIssueCount,
            credentialsConfigured: snapshot.credentialsConfigured
        )
    }
}
