import Foundation
import NativeQobuzCore

@MainActor
final class NativeArchiveRepairStager {
    private let queue: NativeQueueController
    private let ledger: NativeDownloadLedger

    init(queue: NativeQueueController, ledger: NativeDownloadLedger) {
        self.queue = queue
        self.ledger = ledger
    }

    func stage(_ tracks: [QobuzArchiveTrack]) -> [UUID] {
        let repairable = tracks.filter(\.isAutomaticallyRepairable)
        var ids: [UUID] = []
        var seenPaths = Set<String>()

        for target in repairable where seenPaths.insert(target.relativePath).inserted {
            let request = QobuzRequest.track(QobuzID(target.qobuzTrackID))
            if let existing = queue.items.first(where: {
                $0.repairTarget?.relativePath == target.relativePath
                    || ($0.repairTarget == nil && $0.canonicalURL == request.canonicalURL)
            }) {
                guard !ledger.status(forQueueID: existing.id).isActive else { continue }
                queue.update(existing.id) { item in
                    item.repairTarget = target
                    item.title = URL(fileURLWithPath: target.relativePath).lastPathComponent
                    item.subtitle = "Repair · \(target.audioFormat?.displayName ?? "Format \(target.formatID)")"
                }
                ledger.transition(queueID: existing.id, to: .ready)
                ids.append(existing.id)
            } else {
                let item = NativeQueueItem(repairTarget: target)
                queue.append(item)
                ledger.registerQueue(item.id)
                ids.append(item.id)
            }
        }
        return ids
    }
}
