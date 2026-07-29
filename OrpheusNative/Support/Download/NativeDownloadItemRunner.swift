import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadItemRunner {
    private let ledger: NativeDownloadLedger
    private let connectivity: NativeConnectivityController
    private let powerActivityManager: any NativePowerActivityManaging

    init(
        ledger: NativeDownloadLedger,
        connectivity: NativeConnectivityController,
        powerActivityManager: any NativePowerActivityManaging
    ) {
        self.ledger = ledger
        self.connectivity = connectivity
        self.powerActivityManager = powerActivityManager
    }

    func run(
        item: NativeQueueItem,
        engine: NativeQobuzDownloadEngine,
        quality: QobuzQuality,
        root: URL,
        indexLibrary: @escaping @MainActor (URL, [URL]) async throws -> Void,
        isTerminating: @escaping @MainActor () -> Bool,
        checkpoint: @escaping @MainActor () -> Void
    ) async {
        let repairFormat = item.repairTarget?.audioFormat
        let activityID = ledger.prepareActivity(
            for: item,
            quality: quality,
            repairFormat: repairFormat,
            root: root
        )
        let operationMetadata = [
            "queueID": item.id.uuidString,
            "activityID": activityID.uuidString,
            "requestKind": item.request.kindName,
            "qobuzID": item.request.id.rawValue,
            "qualityPolicy": repairFormat == nil ? quality.rawValue : "exact-archive-repair",
            "requestedFormatID": String((repairFormat ?? quality.maximumFormat).formatID),
            "downloadRoot": root.standardizedFileURL.path,
            "repair": String(item.repairTarget != nil),
            "selectedTrackCount": item.selectedTrackIDs.map { String($0.count) } ?? "all"
        ]
        let startedAt = Date()
        qobuzLog.notice(
            "download.item",
            "Queue item download started",
            metadata: operationMetadata.merging([
                "partialResumeBytes": ledger.partialRegardlessOfStatus(for: activityID)
                    .map { String($0.bytes) } ?? "0"
            ]) { _, new in new }
        )
        checkpoint()

        await QobuzLogScope.withValue(operationMetadata) {
            var connectivityRecovery = NativeConnectivityRecoveryPolicy()
            var refreshedExpiredURL = false
            while !Task.isCancelled {
                do {
                    try await withNativePowerActivity(
                        using: powerActivityManager,
                        reason: "Downloading \(item.title)"
                    ) {
                        let events = if let repairTarget = item.repairTarget {
                            try engine.repairEvents(for: repairTarget, downloadRoot: root)
                        } else {
                            engine.events(
                                for: item.request,
                                quality: quality,
                                downloadRoot: root,
                                includedTrackIDs: item.selectedTrackIDs
                            )
                        }
                        for try await event in events {
                            try Task.checkCancellation()
                            ledger.handle(event, activityID: activityID)
                            if case .checkpoint = event { checkpoint() }
                        }
                    }
                    let changedAudioURLs = ledger.activity(id: activityID)?.operation.outputURLs ?? []
                    ledger.transition(queueID: item.id, activityID: activityID, to: .indexingLibrary)
                    ledger.updateActivity(activityID) {
                        $0.recordCheckpoint(QobuzDownloadCheckpoint(phase: .indexingLibrary))
                        $0.phase = "Indexing Library"
                        $0.bytesPerSecond = nil
                    }
                    checkpoint()
                    try await indexLibrary(root, changedAudioURLs)
                    ledger.markLibraryIndexed(queueID: item.id, activityID: activityID)
                    checkpoint()
                    qobuzLog.notice(
                        "download.item",
                        "Queue item download completed",
                        metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))]
                    )
                    return
                } catch let error where error.isQobuzCancellation {
                    finishCancellation(
                        queueID: item.id,
                        activityID: activityID,
                        startedAt: startedAt,
                        isTerminating: isTerminating(),
                        root: root
                    )
                    return
                } catch let error as NativeQobuzError where error.requiresFreshSignedURL && !refreshedExpiredURL {
                    refreshedExpiredURL = true
                    let partialExists = ledger.refreshPartial(for: activityID, root: root) != nil
                    qobuzLog.warning(
                        "download.recovery.url",
                        "Expired audio URL detected; reacquiring a fresh signed Qobuz URL",
                        metadata: ["partialPreserved": String(partialExists)],
                        error: error
                    )
                    ledger.transition(queueID: item.id, activityID: activityID, to: .queued)
                    ledger.updateActivity(activityID) {
                        $0.phase = "Refreshing expired Qobuz link"
                        $0.errorMessage = nil
                        $0.bytesPerSecond = nil
                    }
                    checkpoint()
                    continue
                } catch let error as NativeQobuzError where error.isConnectivityLoss {
                    let generationAtFailure = connectivity.generation
                    let partial = ledger.refreshPartial(for: activityID, root: root)
                    qobuzLog.warning(
                        "download.recovery.network",
                        "Queue item is waiting for network recovery",
                        metadata: [
                            "connectivity": connectivity.state.rawValue,
                            "connectivityGeneration": String(generationAtFailure),
                            "partialPath": partial?.url.path ?? "none",
                            "partialBytes": partial.map { String($0.bytes) } ?? "0"
                        ],
                        error: error
                    )
                    ledger.transition(queueID: item.id, activityID: activityID, to: .waitingForNetwork)
                    ledger.updateActivity(activityID) {
                        $0.phase = partial == nil
                            ? "Waiting for network · resumes automatically"
                            : "Waiting for network · partial file preserved"
                        $0.errorMessage = nil
                        $0.bytesPerSecond = nil
                    }
                    checkpoint()

                    switch connectivityRecovery.action(
                        state: connectivity.state,
                        generation: generationAtFailure
                    ) {
                    case .retryNow:
                        qobuzLog.info(
                            "download.recovery.network",
                            "System path is online; refreshing the signed URL once",
                            metadata: ["connectivityGeneration": String(generationAtFailure)]
                        )
                    case .waitForChange(let generation):
                        do {
                            try await connectivity.waitForOnline(after: generation)
                        } catch {
                            finishCancellation(
                                queueID: item.id,
                                activityID: activityID,
                                startedAt: startedAt,
                                isTerminating: isTerminating(),
                                root: root
                            )
                            return
                        }
                        connectivityRecovery.recovered()
                        refreshedExpiredURL = false
                        qobuzLog.notice(
                            "download.recovery.network",
                            "Network path recovered; resuming with a fresh signed URL",
                            metadata: ["connectivityGeneration": String(connectivity.generation)]
                        )
                    }
                    ledger.transition(queueID: item.id, activityID: activityID, to: .queued)
                    ledger.updateActivity(activityID) {
                        $0.phase = "Network restored · refreshing Qobuz link"
                        $0.errorMessage = nil
                    }
                    continue
                } catch let error as NativeQobuzError where error.canResumeTransfer {
                    let partial = ledger.refreshPartial(for: activityID, root: root)
                    qobuzLog.warning(
                        "download.item",
                        "Queue item download paused after a resumable failure",
                        metadata: [
                            "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                            "partialPath": partial?.url.path ?? "none"
                        ],
                        error: error
                    )
                    ledger.transition(queueID: item.id, activityID: activityID, to: .paused)
                    ledger.updateActivity(activityID) {
                        $0.phase = "Paused · \(error.localizedDescription)"
                        $0.errorMessage = error.localizedDescription
                        $0.bytesPerSecond = nil
                    }
                    checkpoint()
                    return
                } catch {
                    _ = ledger.refreshPartial(for: activityID, root: root)
                    qobuzLog.error(
                        "download.item",
                        "Queue item download failed",
                        metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))],
                        error: error
                    )
                    ledger.transition(
                        queueID: item.id,
                        activityID: activityID,
                        to: .failed(error.localizedDescription)
                    )
                    ledger.updateActivity(activityID) {
                        $0.phase = error.localizedDescription
                        $0.errorMessage = error.localizedDescription
                        $0.bytesPerSecond = nil
                    }
                    checkpoint()
                    return
                }
            }
            finishCancellation(
                queueID: item.id,
                activityID: activityID,
                startedAt: startedAt,
                isTerminating: isTerminating(),
                root: root
            )
        }
    }

    private func finishCancellation(
        queueID: UUID,
        activityID: UUID,
        startedAt: Date,
        isTerminating: Bool,
        root: URL
    ) {
        _ = ledger.refreshPartial(for: activityID, root: root)
        qobuzLog.notice(
            "download.item",
            isTerminating ? "Queue item paused for app termination" : "Queue item download cancelled",
            metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))]
        )
        ledger.transition(
            queueID: queueID,
            activityID: activityID,
            to: isTerminating ? .paused : .cancelled
        )
        ledger.updateActivity(activityID) {
            $0.phase = isTerminating ? "Paused after app closed" : "Cancelled"
            if !isTerminating { $0.errorMessage = nil }
            $0.bytesPerSecond = nil
        }
    }
}
