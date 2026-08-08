import Foundation

/// Process-lifetime cache of provenance-backed reusable audio. The engine
/// still validates every candidate before reuse; this only avoids repeatedly
/// walking the complete Library for each queue item and batch.
public final class QobuzReusableAudioIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var valuesByRoot: [String: [String: URL]] = [:]

    public init() {}

    public func values(
        for root: URL,
        loading: () throws -> [String: URL]
    ) rethrows -> [String: URL] {
        let key = root.standardizedFileURL.path
        if let cached = withLock({ valuesByRoot[key] }) { return cached }
        let loaded = try loading()
        return withLock {
            if let cached = valuesByRoot[key] { return cached }
            valuesByRoot[key] = loaded
            return loaded
        }
    }

    public func store(_ url: URL, reuseKey: String, root: URL) {
        let rootKey = root.standardizedFileURL.path
        withLock { valuesByRoot[rootKey, default: [:]][reuseKey] = url }
    }

    public func remove(reuseKey: String, root: URL) {
        let rootKey = root.standardizedFileURL.path
        withLock { valuesByRoot[rootKey]?[reuseKey] = nil }
    }

    public func invalidate(root: URL) {
        let key = root.standardizedFileURL.path
        withLock { valuesByRoot[key] = nil }
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
