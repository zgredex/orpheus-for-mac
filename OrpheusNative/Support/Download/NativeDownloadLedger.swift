import Combine
import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadLedger: ObservableObject {
    private var state = NativeDownloadStateStore()

    private var lastProgressUpdate: [UUID: Date] = [:]
    private let partialLocator: NativePartialDownloadLocator

    init(partialLocator: NativePartialDownloadLocator = NativePartialDownloadLocator()) {
        self.partialLocator = partialLocator
    }

    var operations: [NativeDownloadOperation] { state.operations }
    var activities: [NativeDownloadActivity] { state.activities }

    func operation(for queueID: UUID) -> NativeDownloadOperation? {
        state.operation(forQueueID: queueID)
    }

    func operation(forActivityID activityID: UUID) -> NativeDownloadOperation? {
        state.operation(forActivityID: activityID)
    }

    func hasLibraryIndexReceipt(for queueID: UUID) -> Bool {
        operation(for: queueID)?.hasLibraryIndexReceipt == true
    }

    func restore(operations: [NativeDownloadOperation]) {
        var restoredState = NativeDownloadStateStore(operations: operations)
        _ = restoredState.normalizeAfterInterruption()
        for operation in restoredState.operations {
            restoredState.mutateOperation(queueID: operation.queueID) {
                $0.resumablePartial = partialLocator.artifact(for: $0)
            }
        }
        state = restoredState
        lastProgressUpdate.removeAll()
        objectWillChange.send()
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
            let partial = partialLocator.artifact(for: operation)
            let isRetry = operation.status.canRetry
            mutateState { state in
                state.mutateOperation(queueID: item.id) {
                    $0.resetForRestart(
                        title: item.title,
                        quality: repairFormat == nil ? quality : nil,
                        audioFormat: repairFormat,
                        downloadRoot: root,
                        phase: partial == nil
                            ? (isRetry ? "Retrying" : "Resuming")
                            : "Resuming existing partial file",
                        resumablePartial: partial
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
                    downloadRoot: root,
                    phase: "Queued",
                    resumablePartial: nil
                )
            }
        }
        return activityID
    }

    func activity(id: UUID) -> NativeDownloadActivity? {
        state.operation(forActivityID: id).map(NativeDownloadActivity.init(operation:))
    }

    func partial(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        let status = status(for: activity)
        guard status.canResume || status.canRetry else { return nil }
        return state.operation(forActivityID: activity.id)?.resumablePartial
    }

    func partialRegardlessOfStatus(for activityID: UUID) -> NativePartialDownload? {
        state.operation(forActivityID: activityID)?.resumablePartial
    }

    @discardableResult
    func refreshPartial(for activityID: UUID) -> NativePartialDownload? {
        guard let operation = state.operation(forActivityID: activityID) else { return nil }
        let partial = partialLocator.artifact(for: operation)
        updateActivity(activityID) { $0.resumablePartial = partial }
        return partial
    }

    func recoveryRoot(for queueID: UUID) -> URL? {
        state.operation(forQueueID: queueID)?.downloadRootURL
    }

    func commitActivityRemoval(_ activityID: UUID, queueStillExists: Bool) {
        mutateState { $0.removeActivity(activityID, queueStillExists: queueStillExists) }
        lastProgressUpdate.removeValue(forKey: activityID)
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
            case .resolvingCatalog, .resolvingAudio: .resolving
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
                activity.resumablePartial = nil
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
                activity.resumablePartial = nil
            }
        }
    }

    func updateActivity(_ id: UUID, mutate: (inout NativeDownloadOperation) -> Void) {
        guard let queueID = state.operation(forActivityID: id)?.queueID else { return }
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
        let previousRevision = state.revision
        mutate(&state)
        if state.revision != previousRevision { objectWillChange.send() }
    }
}
