import Foundation
import NativeQobuzCore
import OSLog

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
        let unifiedRelativePath = "UnifiedLog/unified-log.jsonl"
        let unifiedStatus: NativeDiagnosticArtifactStatus
        let unifiedStartedAt = Date()
        do {
            let outcome = try unifiedLogExporter.export(
                to: bundleRoot.appendingPathComponent(unifiedRelativePath)
            )
            unifiedStatus = Self.status(outcome: outcome, relativePath: unifiedRelativePath)
            qobuzLog.info(
                "diagnostics.supplemental",
                "Current-process Unified Log collection completed",
                metadata: [
                    "entryCount": String(outcome.itemCount),
                    "warningCount": String(outcome.messages.count),
                    "durationMs": String(Int(Date().timeIntervalSince(unifiedStartedAt) * 1_000))
                ]
            )
            for (index, message) in outcome.messages.enumerated() {
                qobuzLog.warning(
                    "diagnostics.supplemental",
                    message,
                    metadata: ["source": "currentProcessUnifiedLog", "messageIndex": String(index)]
                )
            }
        } catch {
            qobuzLog.warning(
                "diagnostics.supplemental",
                "Current-process Unified Log was unavailable",
                metadata: [
                    "durationMs": String(Int(Date().timeIntervalSince(unifiedStartedAt) * 1_000))
                ],
                error: error
            )
            unifiedStatus = Self.unavailable(error)
        }

        let crashRelativePath = "CrashReports"
        let crashStatus: NativeDiagnosticArtifactStatus
        let crashStartedAt = Date()
        do {
            let outcome = try crashReportExporter.export(
                to: bundleRoot.appendingPathComponent(crashRelativePath, isDirectory: true)
            )
            crashStatus = Self.status(outcome: outcome, relativePath: crashRelativePath)
            qobuzLog.info(
                "diagnostics.supplemental",
                "Crash report collection completed",
                metadata: [
                    "reportCount": String(outcome.itemCount),
                    "warningCount": String(outcome.messages.count),
                    "durationMs": String(Int(Date().timeIntervalSince(crashStartedAt) * 1_000))
                ]
            )
            for (index, message) in outcome.messages.enumerated() {
                qobuzLog.warning(
                    "diagnostics.supplemental",
                    message,
                    metadata: ["source": "crashReports", "messageIndex": String(index)]
                )
            }
        } catch {
            qobuzLog.warning(
                "diagnostics.supplemental",
                "macOS crash reports were unavailable",
                metadata: [
                    "durationMs": String(Int(Date().timeIntervalSince(crashStartedAt) * 1_000))
                ],
                error: error
            )
            crashStatus = Self.unavailable(error)
        }

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
    private let fileManager: FileManager

    init(
        subsystem: String = "com.orpheus.formac",
        maximumEntries: Int = 20_000,
        sessionStartedAt: @escaping @Sendable () -> Date = { QobuzDiagnostics.shared.sessionStartedAt },
        fileManager: FileManager = .default
    ) {
        self.subsystem = subsystem
        self.maximumEntries = max(maximumEntries, 1)
        self.sessionStartedAt = sessionStartedAt
        self.fileManager = fileManager
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
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: [.atomic])
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

final class NativeCrashReportExporter: NativeCrashReportExporting, @unchecked Sendable {
    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private let sourceDirectories: [URL]
    private let bundleIdentifier: String
    private let processNames: [String]
    private let maximumReports: Int
    private let maximumAge: TimeInterval
    private let maximumReportBytes: Int64
    private let maximumScannedFiles: Int
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    init(
        sourceDirectories: [URL] = NativeCrashReportExporter.defaultSourceDirectories(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.orpheus.formac",
        processNames: [String] = ["OrpheusNative", "Orpheus for Mac"],
        maximumReports: Int = 10,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60,
        maximumReportBytes: Int64 = 20 * 1_024 * 1_024,
        maximumScannedFiles: Int = 2_000,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.sourceDirectories = sourceDirectories
        self.bundleIdentifier = bundleIdentifier
        self.processNames = processNames
        self.maximumReports = max(maximumReports, 1)
        self.maximumAge = maximumAge
        self.maximumReportBytes = maximumReportBytes
        self.maximumScannedFiles = max(maximumScannedFiles, 1)
        self.now = now
        self.fileManager = fileManager
    }

    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome {
        let discovery = candidateReports()
        let candidates = discovery.candidates
        var messages = discovery.messages
        let selected = Array(candidates.prefix(maximumReports))
        if candidates.count > maximumReports {
            messages.append("Crash report export was limited to the newest \(maximumReports) matching reports.")
        }
        guard !selected.isEmpty else {
            return NativeDiagnosticArtifactOutcome(itemCount: 0, messages: messages)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var exported = 0
        for candidate in selected {
            do {
                let data = try Data(contentsOf: candidate.url, options: [.mappedIfSafe])
                let redacted = QobuzDiagnostics.redact(String(decoding: data, as: UTF8.self))
                let target = uniqueDestination(
                    for: candidate.url.lastPathComponent,
                    in: destination,
                    sequence: exported
                )
                try Data(redacted.utf8).write(to: target, options: [.atomic])
                exported += 1
            } catch {
                let native = error as NSError
                messages.append(QobuzDiagnostics.redact(
                    "Could not export \(candidate.url.lastPathComponent): \(native.domain)[\(native.code)] \(native.localizedDescription)"
                ))
            }
        }
        return NativeDiagnosticArtifactOutcome(itemCount: exported, messages: messages)
    }

    private func candidateReports() -> (candidates: [Candidate], messages: [String]) {
        let cutoff = now().addingTimeInterval(-maximumAge)
        var candidates: [Candidate] = []
        var messages: [String] = []
        var seen = Set<String>()
        var scannedFiles = 0
        directoryLoop: for directory in sourceDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .fileSizeKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    messages.append(QobuzDiagnostics.redact(
                        "Could not inspect \(url.lastPathComponent): \(error.localizedDescription)"
                    ))
                    return true
                }
            ) else {
                messages.append("Could not enumerate crash reports in \(directory.path).")
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                guard ["ips", "crash"].contains(url.pathExtension.lowercased()) else { continue }
                scannedFiles += 1
                if scannedFiles > maximumScannedFiles {
                    messages.append("Crash report discovery stopped after \(maximumScannedFiles) candidate reports.")
                    break directoryLoop
                }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .creationDateKey,
                        .fileSizeKey
                    ])
                    guard values.isRegularFile == true else { continue }
                    let modifiedAt = values.contentModificationDate ?? values.creationDate ?? .distantPast
                    guard modifiedAt >= cutoff else { continue }
                    let size = Int64(values.fileSize ?? 0)
                    guard size <= maximumReportBytes else {
                        messages.append("Skipped oversized crash report \(url.lastPathComponent) (\(size) bytes).")
                        continue
                    }
                    guard seen.insert(url.standardizedFileURL.path).inserted,
                          try matchesApplication(url) else { continue }
                    candidates.append(Candidate(url: url, modifiedAt: modifiedAt))
                } catch {
                    messages.append(QobuzDiagnostics.redact(
                        "Could not inspect crash report \(url.lastPathComponent): \(error.localizedDescription)"
                    ))
                }
            }
        }
        let sorted = candidates.sorted { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt
                ? lhs.url.lastPathComponent < rhs.url.lastPathComponent
                : lhs.modifiedAt > rhs.modifiedAt
        }
        return (sorted, messages)
    }

    private func matchesApplication(_ url: URL) throws -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent.localizedLowercase
        if processNames.contains(where: { filename.contains($0.localizedLowercase) }) { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256 * 1_024) ?? Data()
        let text = String(decoding: prefix, as: UTF8.self).localizedLowercase
        return text.contains(bundleIdentifier.localizedLowercase)
            || processNames.contains(where: { text.contains($0.localizedLowercase) })
    }

    private func uniqueDestination(for filename: String, in directory: URL, sequence: Int) -> URL {
        let proposed = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let source = URL(fileURLWithPath: filename)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        return directory.appendingPathComponent("\(stem)-\(sequence + 1).\(ext)")
    }

    private static func defaultSourceDirectories() -> [URL] {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return []
        }
        return [
            library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
            library.appendingPathComponent("Logs/CrashReporter", isDirectory: true)
        ]
    }
}
