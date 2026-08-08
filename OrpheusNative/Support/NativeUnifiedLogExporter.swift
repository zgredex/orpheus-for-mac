import Foundation
import NativeQobuzCore
import OSLog

private struct NativeUnifiedLogRecord: Codable, Sendable {
    let timestamp: Date
    let level: String
    let subsystem: String
    let category: String
    let process: String
    let processIdentifier: Int32
    let sender: String
    let threadIdentifier: UInt64
    let activityIdentifier: UInt64
    let message: String
    let formatString: String
}

final class NativeUnifiedLogExporter: NativeUnifiedLogExporting, @unchecked Sendable {
    private let subsystem: String
    private let maximumEntries: Int
    private let sessionStartedAt: @Sendable () -> Date

    init(
        subsystem: String = "com.orpheus.formac",
        maximumEntries: Int = 20_000,
        sessionStartedAt: @escaping @Sendable () -> Date = { QobuzDiagnostics.shared.sessionStartedAt }
    ) {
        self.subsystem = subsystem
        self.maximumEntries = max(maximumEntries, 1)
        self.sessionStartedAt = sessionStartedAt
    }

    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let earliestDate = sessionStartedAt()
        let entries = try store.getEntries(at: store.position(date: earliestDate))
        var records: [NativeUnifiedLogRecord] = []
        records.reserveCapacity(maximumEntries)
        var replacementIndex = 0
        var wasLimited = false
        for case let entry as OSLogEntryLog in entries {
            guard entry.date >= earliestDate, entry.subsystem == subsystem else { continue }
            let record = NativeUnifiedLogRecord(
                timestamp: entry.date,
                level: Self.name(for: entry.level),
                subsystem: QobuzDiagnostics.redact(entry.subsystem),
                category: QobuzDiagnostics.redact(entry.category),
                process: QobuzDiagnostics.redact(entry.process),
                processIdentifier: entry.processIdentifier,
                sender: QobuzDiagnostics.redact(entry.sender),
                threadIdentifier: entry.threadIdentifier,
                activityIdentifier: entry.activityIdentifier,
                message: QobuzDiagnostics.redact(entry.composedMessage),
                formatString: QobuzDiagnostics.redact(entry.formatString)
            )
            if records.count < maximumEntries {
                records.append(record)
            } else {
                records[replacementIndex] = record
                replacementIndex = (replacementIndex + 1) % maximumEntries
                wasLimited = true
            }
        }
        guard !records.isEmpty else { return NativeDiagnosticArtifactOutcome(itemCount: 0) }
        let chronologicalRecords = wasLimited
            ? Array(records[replacementIndex...]) + Array(records[..<replacementIndex])
            : records
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        var data = Data()
        for record in chronologicalRecords {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try NativeDiagnosticBundleSecurity.createPrivateDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try NativeDiagnosticBundleSecurity.writePrivateFile(data, to: destination)
        return NativeDiagnosticArtifactOutcome(
            itemCount: records.count,
            messages: wasLimited
                ? ["Unified Log export was limited to the newest \(maximumEntries) Orpheus entries."]
                : []
        )
    }

    private static func name(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: "undefined"
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        @unknown default: "unknown"
        }
    }
}
