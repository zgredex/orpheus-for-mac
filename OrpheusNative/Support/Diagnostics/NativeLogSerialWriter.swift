import Foundation
import NativeQobuzCore

/// Owns every mutation of persistent diagnostics on one serial executor.
/// The current JSONL handle remains open, normal events are batched, and
/// warning/error events force all preceding records to stable storage.
final class NativeLogSerialWriter: @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let maximumFileBytes: Int64
    private let maximumArchives: Int
    private let queue = DispatchQueue(label: "com.orpheus.formac.diagnostics.writer", qos: .utility)
    private let codec = NativeLogCodec()
    private let batchBytes = 64 * 1_024
    private let batchEntries = 32
    private let batchDelay: DispatchTimeInterval = .milliseconds(200)

    private var handle: FileHandle?
    private var currentBytes: Int64 = 0
    private var pending = Data()
    private var pendingEntries = 0
    private var flushGeneration: UInt64 = 0
    private var isActive = false
    private var subscribers: [UUID: AsyncStream<QobuzLogEntry>.Continuation] = [:]

    private var currentURL: URL {
        directoryURL.appendingPathComponent("orpheus-current.jsonl")
    }

    init(
        directoryURL: URL,
        fileManager: FileManager,
        maximumFileBytes: Int64,
        maximumArchives: Int
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maximumFileBytes = maximumFileBytes
        self.maximumArchives = maximumArchives
    }

    deinit {
        try? handle?.close()
    }

    func activate() throws {
        try queue.sync {
            guard !isActive else { return }
            try prepareDirectory()
            try openCurrentFile()
            isActive = true
        }
    }

    func append(_ entry: QobuzLogEntry) {
        queue.async { [weak self] in
            guard let self, self.isActive else { return }
            do {
                try self.accept(entry)
            } catch {
                self.recoverAfterWriteFailure()
                self.reportWriteFailure(error)
            }
        }
    }

    func entryStream() -> AsyncStream<QobuzLogEntry> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2_048)) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.subscribers.removeValue(forKey: id) }
            }
            queue.async { [weak self] in self?.subscribers[id] = continuation }
        }
    }

    func loadEntries(limit: Int) throws -> [QobuzLogEntry] {
        try queue.sync {
            try flushPending(synchronize: false)
            return try NativeLogTailReader(codec: codec).loadEntries(
                files: try logFiles(),
                limit: limit
            )
        }
    }

    func copyLogFiles(to destination: URL) throws {
        try queue.sync {
            try flushPending(synchronize: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in try logFiles() {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: source, to: target)
            }
        }
    }

    func clear() throws {
        try queue.sync {
            pending.removeAll(keepingCapacity: true)
            pendingEntries = 0
            flushGeneration &+= 1
            try handle?.close()
            handle = nil
            for url in try logFiles() { try fileManager.removeItem(at: url) }
            try openCurrentFile()
        }
    }

    private func accept(_ entry: QobuzLogEntry) throws {
        let line = try codec.encodeLine(entry)
        let projectedBytes = currentBytes + Int64(pending.count + line.count)
        if currentBytes + Int64(pending.count) > 0, projectedBytes > maximumFileBytes {
            try flushPending(synchronize: false)
            try rotate()
        }
        pending.append(line)
        pendingEntries += 1
        for subscriber in subscribers.values { subscriber.yield(entry) }

        if entry.level >= .warning {
            try flushPending(synchronize: true)
        } else if pending.count >= batchBytes || pendingEntries >= batchEntries {
            try flushPending(synchronize: false)
        } else if pendingEntries == 1 {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flushGeneration &+= 1
        let generation = flushGeneration
        queue.asyncAfter(deadline: .now() + batchDelay) { [weak self] in
            guard let self, self.flushGeneration == generation else { return }
            do { try self.flushPending(synchronize: false) }
            catch {
                self.recoverAfterWriteFailure()
                self.reportWriteFailure(error)
            }
        }
    }

    private func flushPending(synchronize: Bool) throws {
        guard !pending.isEmpty else {
            if synchronize { try handle?.synchronize() }
            return
        }
        guard let handle else {
            throw CocoaError(.fileNoSuchFile)
        }
        try handle.write(contentsOf: pending)
        currentBytes += Int64(pending.count)
        pending.removeAll(keepingCapacity: true)
        pendingEntries = 0
        flushGeneration &+= 1
        if synchronize { try handle.synchronize() }
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let name = "orpheus-\(Self.filenameTimestamp())-\(UUID().uuidString.prefix(8)).jsonl"
        try fileManager.moveItem(at: currentURL, to: directoryURL.appendingPathComponent(name))
        let archives = try logFiles().filter { $0.lastPathComponent != currentURL.lastPathComponent }
        if archives.count > maximumArchives {
            for url in archives.prefix(archives.count - maximumArchives) {
                try fileManager.removeItem(at: url)
            }
        }
        try openCurrentFile()
    }

    private func openCurrentFile() throws {
        if !fileManager.fileExists(atPath: currentURL.path) {
            guard fileManager.createFile(atPath: currentURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let newHandle = try FileHandle(forWritingTo: currentURL)
        currentBytes = Int64(try newHandle.seekToEnd())
        handle = newHandle
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func logFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }
    }

    private func recoverAfterWriteFailure() {
        pending.removeAll(keepingCapacity: true)
        pendingEntries = 0
        flushGeneration &+= 1
        try? handle?.close()
        handle = nil
        try? openCurrentFile()
    }

    private func reportWriteFailure(_ error: Error) {
        let value = "Orpheus diagnostics write failed: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(value.utf8))
    }

    private static func filenameTimestamp() -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            .format(Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}
