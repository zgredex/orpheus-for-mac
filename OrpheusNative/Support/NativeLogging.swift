import Foundation
import NativeQobuzCore

protocol NativeLogStoring: Sendable {
    var directoryURL: URL { get }
    func activate() throws
    func append(_ entry: QobuzLogEntry)
    func loadEntries(limit: Int) throws -> [QobuzLogEntry]
    func entryStream() -> AsyncStream<QobuzLogEntry>
    func flush() throws
    func copyLogFiles(to destination: URL) throws
    func clear() throws
}

final class NativeLogFileStore: NativeLogStoring, @unchecked Sendable {
    let directoryURL: URL
    let maximumFileBytes: Int64
    let maximumArchives: Int
    private let writer: NativeLogSerialWriter

    init(
        paths: NativePaths,
        maximumFileBytes: Int64 = 5 * 1_024 * 1_024,
        maximumArchives: Int = 8
    ) {
        directoryURL = paths.logsDirectory
        self.maximumFileBytes = maximumFileBytes
        self.maximumArchives = maximumArchives
        writer = NativeLogSerialWriter(
            directoryURL: paths.logsDirectory,
            maximumFileBytes: maximumFileBytes,
            maximumArchives: maximumArchives
        )
    }

    func activate() throws {
        try writer.activate()
        QobuzDiagnostics.shared.install { [weak self] entry in self?.append(entry) }
        qobuzLog.notice(
            "lifecycle",
            "Persistent diagnostics activated",
            metadata: [
                "directory": directoryURL.path,
                "maxFileBytes": String(maximumFileBytes),
                "archives": String(maximumArchives),
                "sessionID": QobuzDiagnostics.shared.sessionID.uuidString
            ]
        )
    }

    func append(_ entry: QobuzLogEntry) {
        writer.append(entry)
    }

    func loadEntries(limit: Int = 5_000) throws -> [QobuzLogEntry] {
        try writer.loadEntries(limit: limit)
    }

    func entryStream() -> AsyncStream<QobuzLogEntry> {
        writer.entryStream()
    }

    func flush() throws {
        try writer.flush()
    }

    func copyLogFiles(to destination: URL) throws {
        try writer.copyLogFiles(to: destination)
    }

    func clear() throws {
        try writer.clear()
        qobuzLog.notice("diagnostics", "Diagnostic history cleared by user")
    }
}

struct NativeDiagnosticReport: Codable, Equatable, Sendable {
    let generatedAt: Date
    let diagnosticSessionID: UUID
    let appVersion: String
    let appBuild: String
    let operatingSystem: String
    let architecture: String
    let locale: String
    let timeZone: String
    let downloadQuality: String
    let downloadRoot: String
    let queue: [NativeDiagnosticQueueSummary]
    let activities: [NativeDiagnosticActivitySummary]
    let libraryTrackCount: Int
    let libraryIssueCount: Int
    let credentialsConfigured: Bool
}

struct NativeDiagnosticQueueSummary: Codable, Equatable, Sendable {
    let id: UUID
    let request: String
    let title: String
    let status: String
    let selectedTracks: Int?
    let quality: String?
}

struct NativeDiagnosticActivitySummary: Codable, Equatable, Sendable {
    let id: UUID
    let queueID: UUID
    let title: String
    let status: String
    let phase: String
    let progress: Double
    let outputPath: String?
    let warnings: [String]
    let error: String?
}
