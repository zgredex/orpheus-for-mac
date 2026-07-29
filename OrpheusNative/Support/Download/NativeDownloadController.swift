import AppKit
import Combine
import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadController: ObservableObject {
    @Published private(set) var isDownloading = false

    private let queue: NativeQueueController
    private let ledger: NativeDownloadLedger
    private let connectivity: NativeConnectivityController
    private let powerActivityManager: any NativePowerActivityManaging
    private let reusableAudioIndex = QobuzReusableAudioIndex()
    private var ledgerObservation: AnyCancellable?
    private var downloadTask: Task<Void, Never>?
    private var activeItemDownloadTask: Task<Void, Never>?
    private var activeItemQueueID: UUID?
    private var isTerminating = false
    private var onNotice: ((String) -> Void)?
    private var onRequireSettings: (() -> Void)?
    private var onIndexLibrary: (URL, [URL]) async throws -> Void = { _, _ in
        throw NativeQobuzError.unavailable("The Library index is unavailable.")
    }
    private var onCheckpoint: (() -> Void)?

    init(
        queue: NativeQueueController,
        connectivity: NativeConnectivityController,
        powerActivityManager: any NativePowerActivityManaging,
        ledger: NativeDownloadLedger? = nil
    ) {
        self.queue = queue
        self.connectivity = connectivity
        self.powerActivityManager = powerActivityManager
        let resolvedLedger = ledger ?? NativeDownloadLedger()
        self.ledger = resolvedLedger
        ledgerObservation = resolvedLedger.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var activities: [NativeDownloadActivity] { ledger.activities }
    var operations: [NativeDownloadOperation] { ledger.operations }
    var canClearActivity: Bool { activities.contains { status(for: $0).isClearable } }

    func configureCallbacks(
        onNotice: @escaping (String) -> Void,
        onRequireSettings: @escaping () -> Void,
        onIndexLibrary: @escaping (URL, [URL]) async throws -> Void,
        onCheckpoint: @escaping () -> Void
    ) {
        self.onNotice = onNotice
        self.onRequireSettings = onRequireSettings
        self.onIndexLibrary = onIndexLibrary
        self.onCheckpoint = onCheckpoint
    }

    func restore(operations: [NativeDownloadOperation]) {
        ledger.restore(operations: operations)
    }

    func status(for item: NativeQueueItem) -> NativeDownloadStatus {
        ledger.status(forQueueID: item.id)
    }

    func status(forQueueID queueID: UUID) -> NativeDownloadStatus {
        ledger.status(forQueueID: queueID)
    }

    func status(for activity: NativeDownloadActivity) -> NativeDownloadStatus {
        ledger.status(for: activity)
    }

    func detailError(for activity: NativeDownloadActivity) -> String? {
        activity.errorMessage ?? status(for: activity).failureMessage
    }

    func isStartable(_ item: NativeQueueItem) -> Bool {
        status(for: item).canStart && item.hasSelectedTracks
    }

    func registerQueue(_ id: UUID) {
        ledger.registerQueue(id)
    }

    func registerQueues<S: Sequence>(_ ids: S) where S.Element == UUID {
        ledger.registerQueues(ids)
    }

    func removeQueue(_ id: UUID) {
        ledger.removeQueue(id)
    }

    func resetAfterPlanChange(_ id: UUID) {
        ledger.resetAfterPlanChange(id)
    }

    func markFailed(queueID: UUID, message: String) {
        ledger.transition(queueID: queueID, to: .failed(message))
    }

    func start(
        ids: [UUID],
        client: (any NativeQobuzServicing)?,
        credentialsConfigured: Bool,
        defaultQuality: QobuzQuality,
        defaultRootPath: String
    ) {
        guard downloadTask == nil, let client, credentialsConfigured else {
            qobuzLog.warning(
                "download.batch",
                "Download batch could not start",
                metadata: [
                    "activeBatch": String(downloadTask != nil),
                    "clientAvailable": String(client != nil),
                    "credentialsConfigured": String(credentialsConfigured)
                ]
            )
            if !credentialsConfigured { onRequireSettings?() }
            return
        }
        let readyIDs = ids.filter { id in
            queue.items.first(where: { $0.id == id }).map(isStartable) == true
        }
        guard !readyIDs.isEmpty else {
            qobuzLog.info(
                "download.batch",
                "Download batch had no startable queue items",
                metadata: ["requestedCount": String(ids.count)]
            )
            return
        }

        let batchID = UUID().uuidString
        let batchStarted = Date()
        qobuzLog.notice(
            "download.batch",
            "Download batch started",
            metadata: [
                "downloadBatchID": batchID,
                "requestedCount": String(ids.count),
                "readyCount": String(readyIDs.count)
            ]
        )
        isDownloading = true
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { finishBatch() }
            do {
                let validator = try FFmpegMediaValidator.bundled()
                let engine = NativeQobuzDownloadEngine(
                    service: client,
                    validator: validator,
                    reusableAudioIndex: reusableAudioIndex
                )
                let runner = NativeDownloadItemRunner(
                    ledger: ledger,
                    connectivity: connectivity,
                    powerActivityManager: powerActivityManager
                )
                for id in readyIDs {
                    try Task.checkCancellation()
                    guard var item = queue.items.first(where: { $0.id == id }) else { continue }
                    let quality = item.downloadQuality ?? defaultQuality
                    let root = URL(
                        fileURLWithPath: item.downloadRootPath ?? defaultRootPath,
                        isDirectory: true
                    )
                    if item.repairTarget == nil { item.downloadQuality = quality }
                    item.downloadRootPath = root.standardizedFileURL.path
                    queue.update(id) { $0 = item }

                    let itemTask = Task { [weak self] in
                        guard let self else { return }
                        await QobuzLogScope.withValue(["downloadBatchID": batchID]) {
                            await runner.run(
                                item: item,
                                engine: engine,
                                quality: quality,
                                root: root,
                                indexLibrary: self.onIndexLibrary,
                                isTerminating: { [weak self] in self?.isTerminating == true },
                                checkpoint: { [weak self] in self?.onCheckpoint?() }
                            )
                        }
                    }
                    activeItemDownloadTask = itemTask
                    activeItemQueueID = id
                    await itemTask.value
                    if activeItemQueueID == id {
                        activeItemDownloadTask = nil
                        activeItemQueueID = nil
                    }
                }
                qobuzLog.notice(
                    "download.batch",
                    "Download batch finished",
                    metadata: [
                        "downloadBatchID": batchID,
                        "durationMs": String(Int(Date().timeIntervalSince(batchStarted) * 1_000))
                    ]
                )
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice(
                    "download.batch",
                    "Download batch cancelled",
                    metadata: ["downloadBatchID": batchID]
                )
                if isTerminating { ledger.markActivePaused(phase: "Paused after app closed") }
                else { ledger.markActiveCancelled() }
            } catch {
                qobuzLog.error(
                    "download.batch",
                    "Download batch failed before an item could finish",
                    metadata: ["downloadBatchID": batchID],
                    error: error
                )
                onNotice?(error.localizedDescription)
            }
        }
    }

    func recover(
        _ activity: NativeDownloadActivity,
        action: NativeDownloadRecoveryAction,
        client: (any NativeQobuzServicing)?,
        credentialsConfigured: Bool,
        defaultQuality: QobuzQuality,
        defaultRootPath: String
    ) {
        guard status(for: activity)[keyPath: action.permission] else { return }
        qobuzLog.notice(
            "activity.recovery",
            action.logMessage,
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
        start(
            ids: [activity.queueID],
            client: client,
            credentialsConfigured: credentialsConfigured,
            defaultQuality: defaultQuality,
            defaultRootPath: defaultRootPath
        )
    }

    func canRestart(_ activity: NativeDownloadActivity) -> Bool {
        guard !isDownloading else { return false }
        return queue.items.first(where: { $0.id == activity.queueID }).map(isStartable) == true
    }

    func canCancel(_ activity: NativeDownloadActivity) -> Bool {
        status(for: activity).isActive && activeItemQueueID == activity.queueID
    }

    func cancel(_ activity: NativeDownloadActivity) {
        guard canCancel(activity) else { return }
        qobuzLog.notice(
            "activity.recovery",
            "User requested item cancellation",
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
        activeItemDownloadTask?.cancel()
    }

    func cancelAll() {
        qobuzLog.notice("download.batch", "User requested cancellation of the download batch")
        activeItemDownloadTask?.cancel()
        downloadTask?.cancel()
    }

    func removeActivity(_ activity: NativeDownloadActivity) {
        guard !status(for: activity).isActive else { return }
        let queueStillExists = queue.items.contains { $0.id == activity.queueID }
        ledger.removeActivity(activity, queueStillExists: queueStillExists)
        qobuzLog.info(
            "activity",
            "Activity item removed",
            metadata: ["activityID": activity.id.uuidString, "queueID": activity.queueID.uuidString]
        )
    }

    func clearFinishedActivities() {
        let removedCount = ledger.clearFinished(queueIDs: Set(queue.items.map(\.id)))
        qobuzLog.info(
            "activity",
            "Finished activities and progress samples cleared",
            metadata: ["removedCount": String(removedCount)]
        )
    }

    func resumablePartial(for activity: NativeDownloadActivity, root: URL) -> NativePartialDownload? {
        ledger.partial(for: activity, root: root)
    }

    func reveal(_ activity: NativeDownloadActivity, defaultRootPath: String) {
        let root = URL(fileURLWithPath: defaultRootPath, isDirectory: true).standardizedFileURL
        let resolver = NativeSecureRevealResolver()
        let target: URL
        if let output = activity.outputURL,
           let existing = resolver.existingItem(output, within: root) {
            target = existing
        } else if let partial = ledger.partialRegardlessOfStatus(for: activity.id, root: root) {
            target = partial.url
        } else if let output = activity.outputURL,
                  let folder = resolver.existingItem(output.deletingLastPathComponent(), within: root) {
            target = folder
        } else {
            target = root
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        ledger.markActivePaused(phase: "Paused after app closed")
        onCheckpoint?()
        activeItemDownloadTask?.cancel()
        downloadTask?.cancel()
    }

    func repairArchiveTracks(
        _ tracks: [QobuzArchiveTrack],
        client: (any NativeQobuzServicing)?,
        credentialsConfigured: Bool,
        defaultQuality: QobuzQuality,
        defaultRootPath: String
    ) {
        qobuzLog.notice(
            "library.repair",
            "Library repair requested",
            metadata: [
                "selectedCount": String(tracks.count),
                "problemCount": String(tracks.count { $0.integrity != .verified })
            ]
        )
        guard !isDownloading else {
            qobuzLog.warning("library.repair", "Library repair blocked by an active download")
            onNotice?("Wait for the current download to finish before starting repairs.")
            return
        }
        guard credentialsConfigured else {
            qobuzLog.warning("library.repair", "Library repair blocked because credentials are not configured")
            onNotice?("Configure Qobuz credentials before repairing files.")
            onRequireSettings?()
            return
        }

        let unsupportedCount = tracks.count { $0.integrity != .verified && $0.audioFormat == nil }
        let ids = stageArchiveRepairs(tracks)
        qobuzLog.info(
            "library.repair",
            "Library repairs staged",
            metadata: ["stagedCount": String(ids.count), "unsupportedCount": String(unsupportedCount)]
        )
        guard !ids.isEmpty else {
            if unsupportedCount > 0 {
                onNotice?("The selected archive formats cannot be repaired automatically.")
            }
            return
        }
        if unsupportedCount > 0 {
            onNotice?("Skipped \(unsupportedCount) unsupported archive format\(unsupportedCount == 1 ? "" : "s").")
        }
        start(
            ids: ids,
            client: client,
            credentialsConfigured: credentialsConfigured,
            defaultQuality: defaultQuality,
            defaultRootPath: defaultRootPath
        )
    }

    @discardableResult
    func stageArchiveRepairs(_ tracks: [QobuzArchiveTrack]) -> [UUID] {
        let repairable = tracks.filter { $0.integrity != .verified && $0.audioFormat != nil }
        var ids: [UUID] = []
        var seenPaths = Set<String>()
        for target in repairable where seenPaths.insert(target.relativePath).inserted {
            let request = QobuzRequest.track(QobuzID(target.qobuzTrackID))
            if let existing = queue.items.first(where: {
                $0.repairTarget?.relativePath == target.relativePath
                    || ($0.repairTarget == nil && $0.canonicalURL == request.canonicalURL)
            }) {
                guard !status(for: existing).isActive else { continue }
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

    private func finishBatch() {
        activeItemDownloadTask?.cancel()
        activeItemDownloadTask = nil
        activeItemQueueID = nil
        downloadTask = nil
        isDownloading = false
    }
}
