import Foundation
import NativeQobuzCore

/// Immutable search material plus bounded indexes for the diagnostics UI.
/// Expensive normalization happens once when an event enters the collection,
/// rather than whenever SwiftUI reevaluates the view body.
struct NativeLogQueryIndex {
    private struct Record {
        let entry: QobuzLogEntry
        let searchCorpus: String
    }

    private let limit: Int
    private var records: [Record] = []
    private var firstRecord = 0
    private var ids = Set<UUID>()
    private var entriesByID: [UUID: QobuzLogEntry] = [:]
    private var levelCounts: [QobuzLogLevel: Int] = [:]
    private var categoryCounts: [String: Int] = [:]

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var count: Int { records.count - firstRecord }
    var categories: [String] { categoryCounts.keys.sorted() }

    func entry(id: UUID) -> QobuzLogEntry? {
        entriesByID[id]
    }

    func count(for level: QobuzLogLevel) -> Int {
        levelCounts[level, default: 0]
    }

    func filtered(
        minimumLevel: QobuzLogLevel,
        category: String,
        query: String
    ) -> [QobuzLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return records[firstRecord...].compactMap { record in
            guard record.entry.level >= minimumLevel else { return nil }
            guard category == "All" || record.entry.category == category else { return nil }
            guard needle.isEmpty || record.searchCorpus.contains(needle) else { return nil }
            return record.entry
        }
    }

    mutating func replace(with entries: [QobuzLogEntry]) {
        records.removeAll(keepingCapacity: true)
        firstRecord = 0
        ids.removeAll(keepingCapacity: true)
        entriesByID.removeAll(keepingCapacity: true)
        levelCounts.removeAll(keepingCapacity: true)
        categoryCounts.removeAll(keepingCapacity: true)
        for entry in entries.suffix(limit) {
            insert(entry)
        }
    }

    mutating func append(_ entry: QobuzLogEntry) {
        guard !ids.contains(entry.id) else { return }
        insert(entry)
        while count > limit { evictOldest() }
        compactStorageIfNeeded()
    }

    private mutating func insert(_ entry: QobuzLogEntry) {
        guard ids.insert(entry.id).inserted else { return }
        records.append(Record(entry: entry, searchCorpus: Self.searchCorpus(for: entry)))
        entriesByID[entry.id] = entry
        levelCounts[entry.level, default: 0] += 1
        categoryCounts[entry.category, default: 0] += 1
    }

    private mutating func evictOldest() {
        guard firstRecord < records.count else { return }
        let entry = records[firstRecord].entry
        firstRecord += 1
        ids.remove(entry.id)
        entriesByID.removeValue(forKey: entry.id)
        decrement(entry.level, in: &levelCounts)
        decrement(entry.category, in: &categoryCounts)
    }

    private mutating func compactStorageIfNeeded() {
        guard firstRecord >= 512, firstRecord * 2 >= records.count else { return }
        records.removeFirst(firstRecord)
        firstRecord = 0
    }

    private func decrement<Key: Hashable>(_ key: Key, in counts: inout [Key: Int]) {
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
    }

    private static func searchCorpus(for entry: QobuzLogEntry) -> String {
        var values = [
            entry.message,
            entry.category,
            entry.sourceFile,
            entry.sourceFunction,
            entry.errorType,
            entry.errorDescription,
            entry.errorDomain,
            entry.errorFailureReason,
            entry.errorRecoverySuggestion,
            entry.underlyingErrors.map { $0.joined(separator: " ") },
            entry.callStack.map { $0.joined(separator: " ") }
        ].compactMap { $0 }
        values.reserveCapacity(values.count + entry.metadata.count * 2)
        for (key, value) in entry.metadata {
            values.append(key)
            values.append(value)
        }
        return values.joined(separator: "\n").localizedLowercase
    }
}
