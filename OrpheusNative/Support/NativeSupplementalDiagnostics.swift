import Foundation
import NativeQobuzCore

enum NativeDiagnosticCollectionState: String, Codable, Equatable, Sendable {
    case collected
    case empty
    case unavailable
}

struct NativeDiagnosticArtifactStatus: Codable, Equatable, Sendable {
    let state: NativeDiagnosticCollectionState
    let itemCount: Int
    let relativePath: String?
    let messages: [String]
}

struct NativeSupplementalDiagnosticSummary: Codable, Equatable, Sendable {
    let generatedAt: Date
    let currentProcessUnifiedLog: NativeDiagnosticArtifactStatus
    let crashReports: NativeDiagnosticArtifactStatus
    let systemWideUnifiedLogIncluded: Bool
}

struct NativeDiagnosticArtifactOutcome: Equatable, Sendable {
    let itemCount: Int
    let messages: [String]

    init(itemCount: Int, messages: [String] = []) {
        self.itemCount = itemCount
        self.messages = messages
    }
}

protocol NativeUnifiedLogExporting: Sendable {
    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome
}

protocol NativeCrashReportExporting: Sendable {
    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome
}

protocol NativeSupplementalDiagnosticsCollecting: Sendable {
    func collect(into bundleRoot: URL) -> NativeSupplementalDiagnosticSummary
}

private struct NativeDiagnosticArtifactRequest {
    let relativePath: String
    let destinationIsDirectory: Bool
    let completedMessage: String
    let unavailableMessage: String
    let itemCountKey: String
    let warningSource: String
    let export: (URL) throws -> NativeDiagnosticArtifactOutcome
}

final class NativeSupplementalDiagnosticsCollector: NativeSupplementalDiagnosticsCollecting, @unchecked Sendable {
    private let unifiedLogExporter: any NativeUnifiedLogExporting
    private let crashReportExporter: any NativeCrashReportExporting

    init(
        unifiedLogExporter: any NativeUnifiedLogExporting = NativeUnifiedLogExporter(),
        crashReportExporter: any NativeCrashReportExporting = NativeCrashReportExporter()
    ) {
        self.unifiedLogExporter = unifiedLogExporter
        self.crashReportExporter = crashReportExporter
    }

    func collect(into bundleRoot: URL) -> NativeSupplementalDiagnosticSummary {
        let collectionStartedAt = Date()
        qobuzLog.notice("diagnostics.supplemental", "Supplemental diagnostic collection started")
        let unifiedStatus = collect(
            NativeDiagnosticArtifactRequest(
                relativePath: "UnifiedLog/unified-log.jsonl",
                destinationIsDirectory: false,
                completedMessage: "Current-process Unified Log collection completed",
                unavailableMessage: "Current-process Unified Log was unavailable",
                itemCountKey: "entryCount",
                warningSource: "currentProcessUnifiedLog",
                export: unifiedLogExporter.export
            ),
            into: bundleRoot
        )
        let crashStatus = collect(
            NativeDiagnosticArtifactRequest(
                relativePath: "CrashReports",
                destinationIsDirectory: true,
                completedMessage: "Crash report collection completed",
                unavailableMessage: "macOS crash reports were unavailable",
                itemCountKey: "reportCount",
                warningSource: "crashReports",
                export: crashReportExporter.export
            ),
            into: bundleRoot
        )

        let summary = NativeSupplementalDiagnosticSummary(
            generatedAt: Date(),
            currentProcessUnifiedLog: unifiedStatus,
            crashReports: crashStatus,
            systemWideUnifiedLogIncluded: false
        )
        qobuzLog.notice(
            "diagnostics.supplemental",
            "Supplemental diagnostic collection finished",
            metadata: [
                "unifiedLogStatus": unifiedStatus.state.rawValue,
                "unifiedLogEntries": String(unifiedStatus.itemCount),
                "crashReportStatus": crashStatus.state.rawValue,
                "crashReports": String(crashStatus.itemCount),
                "systemWideLogIncluded": "false",
                "durationMs": String(Int(Date().timeIntervalSince(collectionStartedAt) * 1_000))
            ]
        )
        return summary
    }

    private func collect(
        _ request: NativeDiagnosticArtifactRequest,
        into bundleRoot: URL
    ) -> NativeDiagnosticArtifactStatus {
        let startedAt = Date()
        let destination = bundleRoot.appendingPathComponent(
            request.relativePath,
            isDirectory: request.destinationIsDirectory
        )
        do {
            let outcome = try request.export(destination)
            qobuzLog.info(
                "diagnostics.supplemental",
                request.completedMessage,
                metadata: [
                    request.itemCountKey: String(outcome.itemCount),
                    "warningCount": String(outcome.messages.count),
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ]
            )
            logWarnings(outcome.messages, source: request.warningSource)
            return Self.status(outcome: outcome, relativePath: request.relativePath)
        } catch {
            qobuzLog.warning(
                "diagnostics.supplemental",
                request.unavailableMessage,
                metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))],
                error: error
            )
            return Self.unavailable(error)
        }
    }

    private func logWarnings(_ messages: [String], source: String) {
        for (index, message) in messages.enumerated() {
            qobuzLog.warning(
                "diagnostics.supplemental",
                message,
                metadata: ["source": source, "messageIndex": String(index)]
            )
        }
    }

    private static func status(
        outcome: NativeDiagnosticArtifactOutcome,
        relativePath: String
    ) -> NativeDiagnosticArtifactStatus {
        NativeDiagnosticArtifactStatus(
            state: outcome.itemCount > 0
                ? .collected
                : (outcome.messages.isEmpty ? .empty : .unavailable),
            itemCount: outcome.itemCount,
            relativePath: outcome.itemCount > 0 ? relativePath : nil,
            messages: outcome.messages.map { QobuzDiagnostics.redact($0) }
        )
    }

    private static func unavailable(_ error: Error) -> NativeDiagnosticArtifactStatus {
        let native = error as NSError
        return NativeDiagnosticArtifactStatus(
            state: .unavailable,
            itemCount: 0,
            relativePath: nil,
            messages: [QobuzDiagnostics.redact(
                "\(native.domain)[\(native.code)]: \(native.localizedDescription)"
            )]
        )
    }
}
