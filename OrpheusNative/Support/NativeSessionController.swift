import Foundation
import NativeQobuzCore

@MainActor
final class NativeSessionController {
    private let store: any NativeSessionStoring
    private let queue: NativeQueueController
    private let downloads: NativeDownloadController
    private let linkInbox: NativeLinkInboxController
    private let writer: NativeSessionPersistenceWriter
    private var persistenceTask: Task<Void, Never>?
    private var isActive = false
    private var isRestoring = false
    private var isTerminating = false
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

    func activate() {
        isActive = true
    }

    func restore() throws {
        guard let snapshot = try store.load() else { return }
        try snapshot.validate()
        writer.setBaseline(snapshot)
        isRestoring = true
        defer { isRestoring = false }

        downloads.restore(operations: snapshot.operations)
        linkInbox.restore(snapshot.linkInbox)
        queue.restore(items: snapshot.queue, selectedID: snapshot.selectedQueueID)
    }

    func schedulePersistence() {
        guard isActive, !isRestoring, !isTerminating else { return }
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            persistenceTask = nil
            enqueueCurrentSnapshot(reportErrors: true)
        }
    }

    func persistCheckpoint() {
        guard isActive, !isRestoring, !isTerminating else { return }
        enqueueCurrentSnapshot(reportErrors: false)
    }

    func persistNow(reportErrors: Bool = true) {
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
        guard !isTerminating else { return }
        isTerminating = true
        persistenceTask?.cancel()
        persistenceTask = nil
    }
}
