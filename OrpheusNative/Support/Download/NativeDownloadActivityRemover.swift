import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadActivityRemover {
    private let ledger: NativeDownloadLedger
    private let cleaner: NativeDownloadRecoveryContextCleaner

    init(
        ledger: NativeDownloadLedger,
        cleaner: NativeDownloadRecoveryContextCleaner = NativeDownloadRecoveryContextCleaner()
    ) {
        self.ledger = ledger
        self.cleaner = cleaner
    }

    @discardableResult
    func remove(
        _ activity: NativeDownloadActivity,
        queueStillExists: Bool,
        onFailure: (String) -> Void
    ) -> Bool {
        guard let operation = ledger.operation(forActivityID: activity.id),
              !operation.status.isActive else { return false }
        do {
            let removedArtifacts = try cleaner.cleanContextOwned(by: operation)
            ledger.commitActivityRemoval(activity.id, queueStillExists: queueStillExists)
            qobuzLog.info(
                "activity",
                "Activity item and owned recovery artifacts removed",
                metadata: [
                    "activityID": activity.id.uuidString,
                    "queueID": operation.queueID.uuidString,
                    "recoveryArtifactCount": String(removedArtifacts.count)
                ]
            )
            return true
        } catch {
            let title = operation.title.isEmpty ? "this download" : "“\(operation.title)”"
            let message = "Could not remove \(title) because its recovery transaction or "
                + ".partial/.processing files could not be cleaned safely. The Activity was kept. "
                + "Check the reported path and folder permissions, then try again. "
                + error.localizedDescription
            qobuzLog.error(
                "activity.cleanup",
                "Activity removal stopped because recovery-context cleanup failed",
                metadata: [
                    "activityID": activity.id.uuidString,
                    "queueID": operation.queueID.uuidString,
                    "downloadRoot": operation.downloadRootURL?.path ?? "unknown"
                ],
                error: error
            )
            onFailure(message)
            return false
        }
    }

    func clearFinished(queueIDs: Set<UUID>, onFailure: (String) -> Void) -> Int {
        let candidates = ledger.activities.filter { ledger.status(for: $0).isClearable }
        var removedCount = 0
        for activity in candidates {
            if remove(
                activity,
                queueStillExists: queueIDs.contains(activity.queueID),
                onFailure: onFailure
            ) {
                removedCount += 1
            }
        }
        qobuzLog.info(
            "activity",
            "Finished activities processed for removal",
            metadata: [
                "candidateCount": String(candidates.count),
                "removedCount": String(removedCount),
                "retainedCount": String(candidates.count - removedCount)
            ]
        )
        return removedCount
    }
}
