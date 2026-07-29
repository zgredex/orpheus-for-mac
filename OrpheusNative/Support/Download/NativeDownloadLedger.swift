import Combine
import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadLedger: ObservableObject {
    @Published private var state = NativeDownloadStateStore()

    private var lastProgressUpdate: [UUID: Date] = [:]
    private let partialLocator: NativePartialDownloadLocator

    init(partialLocator: NativePartialDownloadLocator = NativePartialDownloadLocator()) {
        self.partialLocator = partialLocator
    }

    var operations: [NativeDownloadOperation] { state.operations }
    var activities: [NativeDownloadActivity] { state.activities }

    func restore(operations: [NativeDownloadOperation]) {
        var restoredState = NativeDownloadStateStore(operations: operations)
        _ = restoredState.normalizeAfterInterruption()
        state = restoredState
        lastProgressUpdate.removeAll()
    }

    func status(forQueueID queueID: UUID) -> NativeDownloadStatus {
        state.status(forQueueID: queueID)
    }

    func status(for activity: NativeDownloadActivity) -> NativeDownloadStatus {
        state.status(forActivityID: activity.id) ?? .ready
    }

    func registerQueue(_ id: UUID) {
        mutateState { $0.registerQueue(id) }
    }

    func registerQueues<S: Sequence>(_ ids: S) where S.Element == UUID {
        mutateState { $0.registerQueues(ids) }
    }

    func removeQueue(_ id: UUID) {
        mutateState { $0.removeQueue(id) }
    }

    func resetAfterPlanChange(_ queueID: UUID) {
        switch status(forQueueID: queueID) {
        case .queued, .resolving, .downloading, .tagging, .validating,
             .finalizingAssets, .indexingLibrary, .waitingForNetwork, .ready:
            break
        case .paused, .completed, .failed, .cancelled:
            transition(queueID: queueID, to: .ready)
        }
    }

    func prepareActivity(
        for item: NativeQueueItem,
        quality: QobuzQuality,
        repairFormat: QobuzAudioFormat?,
        root: URL
    ) -> UUID {
        if let operation = state.operation(forQueueID: item.id),
           let activityID = operation.activityID,
           operation.status.canResume || operation.status.canRetry {
            let activity = NativeDownloadActivity(operation: operation)
            let partial = partialLocator.artifact(for: activity, root: root)
            let isRetry = operation.status.canRetry
            mutateState { state in
                state.mutateOperation(queueID: item.id) {
                    $0.resetForRestart(
                        title: item.title,
                        quality: repairFormat == nil ? quality : nil,
                        audioFormat: repairFormat,
                        phase: partial == nil
                            ? (isRetry ? "Retrying" : "Resuming")
                            : "Resuming existing partial file"
                    )
                }
                state.transition(queueID: item.id, activityID: activityID, to: .queued)
            }
            return activityID
        }

        let activityID = UUID()
        mutateState { state in
            state.registerQueue(item.id)
            state.bindActivity(activityID, to: item.id, status: .queued)
            state.mutateOperation(queueID: item.id) {
                $0.resetForRestart(
                    title: item.title,
                    quality: repairFormat == nil ? quality : nil,
                    audioFormat: repairFormat,
                    phase: "Queued"
                )
            }
        }
        return activityID
    }

    func activity(id: UUID) -> NativeDownloadActivity? {
        activities.first { $0.id == id }
    }

    func partial(for activity: NativeDownloadActivity, root: URL) -> NativePartialDownload? {
        let status = status(for: activity)
        guard status.canResume || status.canRetry else { return nil }
        return partialLocator.artifact(for: activity, root: root)
    }

    func partialRegardlessOfStatus(for activityID: UUID, root: URL) -> NativePartialDownload? {
        activity(id: activityID).flatMap { partialLocator.artifact(for: $0, root: root) }
    }

    func removeActivity(_ activity: NativeDownloadActivity, queueStillExists: Bool) {
        guard !status(for: activity).isActive else { return }
        mutateState { $0.removeActivity(activity.id, queueStillExists: queueStillExists) }
        lastProgressUpdate.removeValue(forKey: activity.id)
    }

    func clearFinished(queueIDs: Set<UUID>) -> Int {
        let removed = activities.filter { status(for: $0).isClearable }
        let removedIDs = Set(removed.map(\.id))
        mutateState { state in
            for activity in removed {
                state.removeActivity(activity.id, queueStillExists: queueIDs.contains(activity.queueID))
            }
        }
        lastProgressUpdate = lastProgressUpdate.filter { !removedIDs.contains($0.key) }
        return removedIDs.count
    }

    func handle(_ event: QobuzDownloadEvent, activityID: UUID) {
        if case .progress(let progress) = event, (progress.currentTrackFraction ?? 1) < 1 {
            let now = Date()
            if let last = lastProgressUpdate[activityID], now.timeIntervalSince(last) < 0.2 { return }
            lastProgressUpdate[activityID] = now
        } else {
            lastProgressUpdate[activityID] = nil
        }

        let queueID = activity(id: activityID)?.queueID
        let nextStatus: NativeDownloadStatus? = switch event {
        case .checkpoint(let checkpoint): switch checkpoint.phase {
            case .resolvingCatalog: .resolving
            case .transferringAudio: .downloading
            case .writingTags: .tagging
            case .validatingAudio, .writingProvenance: .validating
            case .writingCollectionAssets: .finalizingAssets
            case .indexingLibrary, .complete: .indexingLibrary
            }
        case .resolving: .resolving
        case .trackStarted, .progress: .downloading
        case .tagging: .tagging
        case .validating: .validating
        case .completed: .indexingLibrary
        default: nil
        }
        if let queueID, let nextStatus {
            transition(queueID: queueID, activityID: activityID, to: nextStatus)
        }
        updateActivity(activityID) { activity in
            switch event {
            case .checkpoint(let checkpoint):
                activity.recordCheckpoint(checkpoint)
            case .resolving:
                activity.phase = "Resolving Qobuz"
            case .planReady(let title, let count):
                activity.title = title
                activity.totalTracks = count
                activity.phase = "Preparing media"
            case .trackStarted(let track, let destination, let format):
                activity.phase = "Downloading"
                activity.currentTrack = track.track.displayTitle
                activity.recordOutput(destination)
                activity.audioFormat = format
                activity.bytesPerSecond = nil
            case .progress(let progress):
                activity.progress = progress.overallFraction
                activity.completedTracks = progress.completedTracks
                activity.totalTracks = progress.totalTracks
                if let written = progress.bytesWritten { activity.bytesWritten = written }
                if let total = progress.totalBytes { activity.totalBytes = total }
                if let speed = progress.bytesPerSecond { activity.bytesPerSecond = speed }
                if let album = progress.albumBytesWritten { activity.albumBytesWritten = album }
            case .tagging:
                activity.phase = "Writing metadata"
            case .validating:
                activity.phase = "Checking audio integrity"
            case .integrityVerified(_, let checksum):
                activity.checksum = checksum
                activity.phase = "Integrity verified"
            case .assetCreated(let url):
                activity.recordAsset(url)
                activity.phase = "Created \(url.lastPathComponent)"
            case .notice(let message):
                if !activity.notices.contains(message) { activity.notices.append(message) }
            case .warning(let message):
                if !activity.warnings.contains(message) { activity.warnings.append(message) }
                activity.phase = "Finishing with warnings"
            case .trackCompleted(_, let destination), .trackSkipped(_, let destination):
                activity.recordOutput(destination)
            case .completed:
                activity.phase = "Indexing Library"
                activity.progress = 1
                activity.bytesPerSecond = nil
            }
        }
    }

    func updateActivity(_ id: UUID, mutate: (inout NativeDownloadOperation) -> Void) {
        guard let queueID = state.operations.first(where: { $0.activityID == id })?.queueID else { return }
        mutateState { $0.mutateOperation(queueID: queueID, mutate) }
    }

    func transition(queueID: UUID, activityID: UUID? = nil, to status: NativeDownloadStatus) {
        let previous = state.operation(forQueueID: queueID)
        mutateState { $0.transition(queueID: queueID, activityID: activityID, to: status) }
        guard previous?.status != status || (activityID != nil && previous?.activityID != activityID) else { return }
        qobuzLog.debug(
            "download.lifecycle",
            "Download operation transitioned",
            metadata: [
                "queueID": queueID.uuidString,
                "activityID": activityID?.uuidString ?? previous?.activityID?.uuidString ?? "none",
                "from": previous?.status.diagnosticDescription ?? "unregistered",
                "to": status.diagnosticDescription
            ]
        )
    }

    func markLibraryIndexed(queueID: UUID, activityID: UUID) {
        updateActivity(activityID) {
            $0.recordCheckpoint(QobuzDownloadCheckpoint(phase: .complete))
            $0.phase = $0.warnings.isEmpty ? "Complete" : "Complete with warnings"
            $0.progress = 1
            $0.bytesPerSecond = nil
        }
        transition(queueID: queueID, activityID: activityID, to: .completed)
    }

    func markActiveCancelled() {
        let active = activities.filter { status(for: $0).isActive }.map { ($0.queueID, $0.id) }
        for (queueID, activityID) in active {
            transition(queueID: queueID, activityID: activityID, to: .cancelled)
            updateActivity(activityID) { $0.phase = "Cancelled" }
        }
    }

    func markActivePaused(phase: String) {
        let active = activities.filter { status(for: $0).isActive }.map { ($0.queueID, $0.id) }
        for (queueID, activityID) in active {
            transition(queueID: queueID, activityID: activityID, to: .paused)
            updateActivity(activityID) {
                $0.phase = phase
                $0.bytesPerSecond = nil
            }
        }
    }

    private func mutateState(_ mutate: (inout NativeDownloadStateStore) -> Void) {
        var updated = state
        mutate(&updated)
        if updated != state { state = updated }
    }
}
