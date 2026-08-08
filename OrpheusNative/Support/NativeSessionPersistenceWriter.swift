import Foundation

/// Serializes session persistence away from the main actor and collapses queued
/// updates to the newest authoritative snapshot.
final class NativeSessionPersistenceWriter: @unchecked Sendable {
    typealias FailureHandler = @Sendable (Error) -> Void

    private struct PendingWrite {
        let snapshot: NativeSessionSnapshot
        let onFailure: FailureHandler
    }

    private let store: any NativeSessionStoring
    private let queue = DispatchQueue(label: "com.orpheus.formac.session-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: PendingWrite?
    private var drainScheduled = false
    private var persisted: NativeSessionSnapshot?

    init(store: any NativeSessionStoring) {
        self.store = store
    }

    func setBaseline(_ snapshot: NativeSessionSnapshot?) {
        queue.sync { persisted = snapshot }
    }

    func enqueue(_ snapshot: NativeSessionSnapshot, onFailure: @escaping FailureHandler) {
        let shouldSchedule = lock.withLock {
            pending = PendingWrite(snapshot: snapshot, onFailure: onFailure)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    func flush(_ snapshot: NativeSessionSnapshot) throws {
        try queue.sync {
            lock.withLock { pending = nil }
            try saveIfChanged(snapshot)
        }
    }

    private func drain() {
        while let write = takePending() {
            do {
                try saveIfChanged(write.snapshot)
            } catch {
                write.onFailure(error)
            }
        }
    }

    private func takePending() -> PendingWrite? {
        lock.withLock {
            guard let value = pending else {
                drainScheduled = false
                return nil
            }
            pending = nil
            return value
        }
    }

    private func saveIfChanged(_ snapshot: NativeSessionSnapshot) throws {
        guard snapshot != persisted else { return }
        try store.save(snapshot)
        persisted = snapshot
    }
}
