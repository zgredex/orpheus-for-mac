import NativeQobuzCore

extension Array where Element == QobuzLogEntry {
    mutating func appendDiagnostic(_ entry: QobuzLogEntry, limit: Int) {
        guard !contains(where: { $0.id == entry.id }) else { return }
        append(entry)
        if count > limit { removeFirst(count - limit) }
    }
}
