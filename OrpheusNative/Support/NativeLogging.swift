import Foundation
import NativeQobuzCore

protocol NativeLogStoring: Sendable {
    var directoryURL: URL { get }
    func activate() throws
    func append(_ entry: QobuzLogEntry)
    func loadEntries(limit: Int) throws -> [QobuzLogEntry]
    func copyLogFiles(to destination: URL) throws
    func clear() throws
}

final class NativeLogFileStore: NativeLogStoring, @unchecked Sendable {
    let directoryURL: URL
    let maximumFileBytes: Int64
    let maximumArchives: Int

    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var isActive = false

    private var currentURL: URL {
        directoryURL.appendingPathComponent("orpheus-current.jsonl")
    }

    init(
        paths: NativePaths = NativePaths(),
        fileManager: FileManager = .default,
        maximumFileBytes: Int64 = 5 * 1_024 * 1_024,
        maximumArchives: Int = 8
    ) {
        directoryURL = paths.logsDirectory
        self.fileManager = fileManager
        self.maximumFileBytes = maximumFileBytes
        self.maximumArchives = maximumArchives
        encoder = Self.makeEncoder()
        decoder = Self.makeDecoder()
    }

    func activate() throws {
        try lock.withLock {
            try prepareDirectory()
            isActive = true
            QobuzDiagnostics.shared.install { [weak self] entry in self?.append(entry) }
        }
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
        lock.withLock {
            guard isActive else { return }
            do {
                try prepareDirectory()
                let data = try encoder.encode(entry) + Data([0x0A])
                try rotateIfNeeded(incomingBytes: Int64(data.count))
                if !fileManager.fileExists(atPath: currentURL.path) {
                    fileManager.createFile(atPath: currentURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: currentURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                if entry.level >= .warning { try handle.synchronize() }
            } catch {
                // The durable sink cannot recursively log its own write failure.
                let value = "Orpheus diagnostics write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(value.utf8))
            }
        }
    }

    func loadEntries(limit: Int = 5_000) throws -> [QobuzLogEntry] {
        try lock.withLock {
            try prepareDirectory()
            var entries: [QobuzLogEntry] = []
            var corruptLines = 0
            for url in try logFiles() {
                let data = try Data(contentsOf: url)
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    do { entries.append(try decoder.decode(QobuzLogEntry.self, from: Data(line))) }
                    catch { corruptLines += 1 }
                }
            }
            entries.sort { lhs, rhs in
                lhs.timestamp == rhs.timestamp ? lhs.uptime < rhs.uptime : lhs.timestamp < rhs.timestamp
            }
            if corruptLines > 0 {
                entries.append(QobuzLogEntry(
                    sessionID: QobuzDiagnostics.shared.sessionID,
                    level: .warning,
                    category: "diagnostics",
                    message: "Some persisted log records could not be decoded",
                    metadata: ["corruptLines": String(corruptLines)],
                    sourceFile: #fileID,
                    sourceFunction: #function,
                    sourceLine: #line,
                    thread: "reader"
                ))
            }
            return Array(entries.suffix(max(limit, 1)))
        }
    }

    func copyLogFiles(to destination: URL) throws {
        try lock.withLock {
            try prepareDirectory()
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in try logFiles() {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: source, to: target)
            }
        }
    }

    func clear() throws {
        try lock.withLock {
            for url in try logFiles() { try fileManager.removeItem(at: url) }
        }
        qobuzLog.notice("diagnostics", "Diagnostic history cleared by user")
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func rotateIfNeeded(incomingBytes: Int64) throws {
        let currentSize = ((try? fileManager.attributesOfItem(atPath: currentURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard currentSize > 0, currentSize + incomingBytes > maximumFileBytes else { return }
        let name = "orpheus-\(Self.filenameTimestamp())-\(UUID().uuidString.prefix(8)).jsonl"
        try fileManager.moveItem(at: currentURL, to: directoryURL.appendingPathComponent(name))
        let archives = try logFiles().filter { $0.lastPathComponent != currentURL.lastPathComponent }
        if archives.count > maximumArchives {
            for url in archives.prefix(archives.count - maximumArchives) { try fileManager.removeItem(at: url) }
        }
    }

    private func logFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return value
    }

    private static func makeDecoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid diagnostic timestamp")
                )
            }
            return date
        }
        return value
    }

    private static func filenameTimestamp() -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            .format(Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}

struct NativeDiagnosticReport: Codable, Equatable {
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

struct NativeDiagnosticQueueSummary: Codable, Equatable {
    let id: UUID
    let request: String
    let title: String
    let status: String
    let selectedTracks: Int?
    let quality: String?
}

struct NativeDiagnosticActivitySummary: Codable, Equatable {
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
