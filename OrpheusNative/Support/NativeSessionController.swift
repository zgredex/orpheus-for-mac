import Foundation
import NativeQobuzCore

@MainActor
final class NativeSessionController {
    private let store: any NativeSessionStoring
    private let queue: NativeQueueController
    private let downloads: NativeDownloadController
    private let linkInbox: NativeLinkInboxController
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
        isRestoring = true
        defer { isRestoring = false }

        downloads.restore(activities: snapshot.activities, operations: snapshot.operations)
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
            persistNow()
        }
    }

    func persistNow(reportErrors: Bool = true) {
        persistenceTask?.cancel()
        persistenceTask = nil
        do {
            try store.save(
                NativeSessionSnapshot(
                    queue: queue.items,
                    activities: downloads.activities,
                    operations: downloads.operations,
                    selectedQueueID: queue.selectedID,
                    linkInbox: linkInbox.items
                )
            )
        } catch where reportErrors {
            qobuzLog.error("persistence.session", "Download session save failed", error: error)
            onFailure?("Could not save the download queue: \(error.localizedDescription)")
        } catch {
            qobuzLog.error("persistence.session", "Background download session save failed", error: error)
        }
    }

    func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        persistenceTask?.cancel()
        persistenceTask = nil
    }
}
