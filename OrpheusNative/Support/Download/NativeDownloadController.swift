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
    private let repairStager: NativeArchiveRepairStager
    private let activityRemover: NativeDownloadActivityRemover
    private let activityRevealResolver = NativeActivityRevealResolver()
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
    private var currentLibrarySnapshot: () -> QobuzArchiveSnapshot? = { nil }
    private var recoveryCleanupAllowed: () -> Bool = { true }

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
        repairStager = NativeArchiveRepairStager(queue: queue, ledger: resolvedLedger)
        activityRemover = NativeDownloadActivityRemover(ledger: resolvedLedger)
        ledgerObservation = resolvedLedger.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var activities: [NativeDownloadActivity] { ledger.activities }
    var operations: [NativeDownloadOperation] { ledger.operations }
    var canClearActivity: Bool { activities.contains { status(for: $0).isClearable } }

    func hasLibraryMutationConflict(at root: URL) -> Bool {
        guard !isDownloading else { return true }
        let rootPath = root.standardizedFileURL.path
        return operations.contains {
            $0.retainsWritableRecoveryContext && $0.downloadRootURL?.path == rootPath
        }
    }

    func configureCallbacks(
        onNotice: @escaping (String) -> Void,
        onRequireSettings: @escaping () -> Void,
        onIndexLibrary: @escaping (URL, [URL]) async throws -> Void,
        onCheckpoint: @escaping () -> Void,
        currentLibrarySnapshot: @escaping () -> QobuzArchiveSnapshot? = { nil },
        recoveryCleanupAllowed: @escaping () -> Bool = { true }
    ) {
        self.onNotice = onNotice
        self.onRequireSettings = onRequireSettings
        self.onIndexLibrary = onIndexLibrary
        self.onCheckpoint = onCheckpoint
        self.currentLibrarySnapshot = currentLibrarySnapshot
        self.recoveryCleanupAllowed = recoveryCleanupAllowed
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

    func canResumeLibraryIndex(_ item: NativeQueueItem) -> Bool {
        isStartable(item) && ledger.hasLibraryIndexReceipt(for: item.id)
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
        guard downloadTask == nil else {
            qobuzLog.warning(
                "download.batch",
                "Download batch could not start because another batch is active"
            )
            return
        }
        let startableIDs = ids.filter { id in
            queue.items.first(where: { $0.id == id }).map(isStartable) == true
        }
        let transferAvailable = client != nil && credentialsConfigured
        let readyIDs = transferAvailable
            ? startableIDs
            : startableIDs.filter(ledger.hasLibraryIndexReceipt(for:))
        guard !readyIDs.isEmpty else {
            qobuzLog.log(
                startableIDs.isEmpty ? .info : .warning,
                category: "download.batch",
                startableIDs.isEmpty
                    ? "Download batch had no startable queue items"
                    : "Download batch requires Qobuz credentials",
                metadata: [
                    "requestedCount": String(ids.count),
                    "clientAvailable": String(client != nil),
                    "credentialsConfigured": String(credentialsConfigured)
                ]
            )
            if !startableIDs.isEmpty { onRequireSettings?() }
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
                "readyCount": String(readyIDs.count),
                "localIndexRecoveryCount": String(readyIDs.count {
                    ledger.hasLibraryIndexReceipt(for: $0)
                })
            ]
        )
        isDownloading = true
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { finishBatch() }
            do {
                let engine: NativeQobuzDownloadEngine? = if readyIDs.contains(where: {
                    !self.ledger.hasLibraryIndexReceipt(for: $0)
                }), let client {
                    NativeQobuzDownloadEngine(
                        service: client,
                        validator: try FFmpegMediaValidator.bundled(),
                        reusableAudioIndex: reusableAudioIndex
                    )
                } else {
                    nil
                }
                let runner = NativeDownloadItemRunner(
                    ledger: ledger,
                    connectivity: connectivity,
                    powerActivityManager: powerActivityManager
                )
                for id in readyIDs {
                    try Task.checkCancellation()
                    guard var item = queue.items.first(where: { $0.id == id }) else { continue }
                    let quality = item.downloadQuality ?? defaultQuality
                    let recoveryRoot = ledger.status(forQueueID: id).canResume
                        || ledger.status(forQueueID: id).canRetry
                        ? ledger.recoveryRoot(for: id)
                        : nil
                    let root = URL(
                        fileURLWithPath: recoveryRoot?.path ?? defaultRootPath,
                        isDirectory: true
                    ).standardizedFileURL
                    if item.repairTarget == nil { item.downloadQuality = quality }
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
        guard canCleanRecoveryFiles() else { return }
        let queueStillExists = queue.items.contains { $0.id == activity.queueID }
        activityRemover.remove(activity, queueStillExists: queueStillExists) { [weak self] message in
            self?.onNotice?(message)
        }
    }

    func clearFinishedActivities() {
        guard canCleanRecoveryFiles() else { return }
        _ = activityRemover.clearFinished(queueIDs: Set(queue.items.map(\.id))) { [weak self] message in
            self?.onNotice?(message)
        }
    }

    func resumablePartial(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        guard status(for: activity).canResume || status(for: activity).canRetry else {
            return nil
        }
        return ledger.refreshPartial(for: activity.id)
    }

    func reveal(_ activity: NativeDownloadActivity) {
        guard let target = activityRevealResolver.target(
            for: activity,
            currentLibrarySnapshot: currentLibrarySnapshot()
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func canCleanRecoveryFiles() -> Bool {
        guard !isDownloading else {
            onNotice?("Wait for the current download to finish before removing recovery files.")
            return false
        }
        guard recoveryCleanupAllowed() else {
            onNotice?("Wait for Library maintenance to finish before removing download recovery files.")
            return false
        }
        return true
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

        let manualActionCount = tracks.count { $0.integrity != .verified && !$0.isAutomaticallyRepairable }
        let ids = stageArchiveRepairs(tracks)
        qobuzLog.info(
            "library.repair",
            "Library repairs staged",
            metadata: ["stagedCount": String(ids.count), "manualActionCount": String(manualActionCount)]
        )
        guard !ids.isEmpty else {
            if manualActionCount > 0 {
                onNotice?("The selected Library problems require manual action.")
            }
            return
        }
        if manualActionCount > 0 {
            onNotice?("Skipped \(manualActionCount) Library problem\(manualActionCount == 1 ? "" : "s") that require\(manualActionCount == 1 ? "s" : "") manual action.")
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
        repairStager.stage(tracks)
    }

    private func finishBatch() {
        activeItemDownloadTask?.cancel()
        activeItemDownloadTask = nil
        activeItemQueueID = nil
        downloadTask = nil
        isDownloading = false
    }
}
