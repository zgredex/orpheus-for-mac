import Foundation
import NativeQobuzCore

@MainActor
final class NativeSessionController {
    private enum Phase: Equatable {
        case idle
        case restoring(UUID)
        case active
        case failed
        case terminating(persistRestoredState: Bool)
    }

    private let store: any NativeSessionStoring
    private let queue: NativeQueueController
    private let downloads: NativeDownloadController
    private let linkInbox: NativeLinkInboxController
    private let writer: NativeSessionPersistenceWriter
    private var persistenceTask: Task<Void, Never>?
    private var phase: Phase = .idle
    private var onFailure: ((String) -> Void)?

    init(
        store: any NativeSessionStoring,
        queue: NativeQueueController,
        downloads: NativeDownloadController,
        linkInbox: NativeLinkInboxController
    ) {
        self.store = store
        self.queue = queue
        self.downloads = downloads
        self.linkInbox = linkInbox
        writer = NativeSessionPersistenceWriter(store: store)
    }

    func configure(onFailure: @escaping (String) -> Void) {
        self.onFailure = onFailure
    }

    func restore(root: URL) async throws {
        guard phase == .idle || phase == .failed else {
            throw NativeQobuzError.unavailable("The download session is not ready to restore.")
        }
        let restorationID = UUID()
        phase = .restoring(restorationID)
        let store = store
        do {
            let restored = try await Task.detached(priority: .userInitiated) {
                try store.load()
            }.value
            try Task.checkCancellation()
            guard phase == .restoring(restorationID) else { throw CancellationError() }
            if let snapshot = restored {
                try snapshot.validate()
                do {
                    try snapshot.validate(restoringAt: root)
                } catch {
                    try store.rejectLoadedSnapshot(cause: error)
                    writer.setBaseline(nil)
                    qobuzLog.warning(
                        "persistence.session",
                        "Saved recovery state was not applied because it belongs to another Library",
                        metadata: ["configuredRoot": root.standardizedFileURL.path],
                        error: error
                    )
                    guard phase == .restoring(restorationID) else { throw CancellationError() }
                    phase = .active
                    return
                }
                writer.setBaseline(snapshot)
                downloads.restore(operations: snapshot.operations)
                linkInbox.restore(snapshot.linkInbox)
                queue.restore(items: snapshot.queue, selectedID: snapshot.selectedQueueID)
            } else {
                writer.setBaseline(nil)
            }
            guard phase == .restoring(restorationID) else { throw CancellationError() }
            phase = .active
        } catch {
            if phase == .restoring(restorationID) { phase = .failed }
            throw error
        }
    }

    func schedulePersistence() {
        guard phase == .active else { return }
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            persistenceTask = nil
            enqueueCurrentSnapshot(reportErrors: true)
        }
    }

    func persistCheckpoint() {
        guard phase == .active else { return }
        enqueueCurrentSnapshot(reportErrors: false)
    }

    func persistNow(reportErrors: Bool = true) {
        guard phase == .active else { return }
        flushCurrentSnapshot(reportErrors: reportErrors)
    }

    func persistForTermination() {
        guard phase == .terminating(persistRestoredState: true) else { return }
        flushCurrentSnapshot(reportErrors: false)
    }

    private func flushCurrentSnapshot(reportErrors: Bool) {
        persistenceTask?.cancel()
        persistenceTask = nil
        do {
            try writer.flush(currentSnapshot)
        } catch where reportErrors {
            qobuzLog.error("persistence.session", "Download session save failed", error: error)
            onFailure?("Could not save the download queue: \(error.localizedDescription)")
        } catch {
            qobuzLog.error("persistence.session", "Background download session save failed", error: error)
        }
    }

    private var currentSnapshot: NativeSessionSnapshot {
        NativeSessionSnapshot(
            queue: queue.items,
            operations: downloads.operations,
            selectedQueueID: queue.selectedID,
            linkInbox: linkInbox.items
        )
    }

    private func enqueueCurrentSnapshot(reportErrors: Bool) {
        writer.enqueue(currentSnapshot) { [weak self] error in
            qobuzLog.error(
                "persistence.session",
                reportErrors
                    ? "Asynchronous download session save failed"
                    : "Asynchronous download checkpoint save failed",
                error: error
            )
            guard reportErrors else { return }
            Task { @MainActor [weak self] in
                self?.onFailure?("Could not save the download queue: \(error.localizedDescription)")
            }
        }
    }

    func beginTermination() {
        guard case .terminating = phase else {
            phase = .terminating(persistRestoredState: phase == .active)
            persistenceTask?.cancel()
            persistenceTask = nil
            return
        }
        persistenceTask?.cancel()
        persistenceTask = nil
    }
}
