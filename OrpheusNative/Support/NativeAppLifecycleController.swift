import Combine
import Foundation
import NativeQobuzCore

enum NativeConfigurationFollowUp {
    case retryStartup
    case saved
    case validateAccount
}

@MainActor
final class NativeAppLifecycleController: ObservableObject {
    private let account: NativeAccountController
    private let browse: NativeBrowseController
    private let queue: NativeQueueController
    private let preview: NativePreviewController
    private let linkInbox: NativeLinkInboxController
    private let library: NativeLibraryController
    private let connectivity: NativeConnectivityController
    private let downloads: NativeDownloadController
    private let session: NativeSessionController
    private let queueOrchestrator: NativeQueueOrchestrator
    private let startupGate = NativeStartupGate()
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private var accountValidationTask: Task<Void, Never>?
    private var startupObservation: AnyCancellable?
    private var terminationObserver: NativeApplicationTerminationObserver?
    private var finalFlush: (() -> Void)?

    init(
        account: NativeAccountController,
        browse: NativeBrowseController,
        queue: NativeQueueController,
        preview: NativePreviewController,
        linkInbox: NativeLinkInboxController,
        library: NativeLibraryController,
        connectivity: NativeConnectivityController,
        downloads: NativeDownloadController,
        session: NativeSessionController,
        queueOrchestrator: NativeQueueOrchestrator
    ) {
        self.account = account
        self.browse = browse
        self.queue = queue
        self.preview = preview
        self.linkInbox = linkInbox
        self.library = library
        self.connectivity = connectivity
        self.downloads = downloads
        self.session = session
        self.queueOrchestrator = queueOrchestrator
        startupObservation = startupGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        terminationObserver = NativeApplicationTerminationObserver { [weak self] in
            self?.prepareForTermination()
        }
    }

    var isReady: Bool { startupGate.isReady }
    var isStarting: Bool { startupGate.isStarting }
    var canRetry: Bool { startupGate.canRetry }
    var canEditConfiguration: Bool { startupGate.canEditConfiguration }

    func requireConfigurationMutationPermission() throws {
        guard canEditConfiguration else {
            throw NativeQobuzError.unavailable(
                "Settings cannot be changed until startup restoration has finished."
            )
        }
    }

    func configureProcessTermination(diagnostics: NativeDiagnosticsController) {
        finalFlush = {
            do {
                try diagnostics.flush()
            } catch {
                qobuzLog.critical("lifecycle", "Final diagnostic flush failed", error: error)
                try? diagnostics.flush()
            }
        }
    }

    func shouldHandleOpenURL(_ url: URL) -> Bool {
        let shouldHandle = startupGate.shouldHandleOpenURL(url)
        guard !shouldHandle else { return true }
        qobuzLog.info(
            "lifecycle.url",
            startupGate.state == .terminating
                ? "Discarded open-URL event during termination"
                : "Buffered open-URL event until startup restoration completes",
            metadata: ["startupState": String(describing: startupGate.state)]
        )
        return false
    }

    func start(
        onValidateAccount: @escaping @MainActor () async -> Void,
        onOpenURL: @escaping @MainActor (URL) -> Void,
        onNotice: @escaping (String) -> Void,
        onRequireSettings: @escaping () -> Void
    ) async {
        guard let startupID = startupGate.begin() else {
            qobuzLog.debug("lifecycle", "Ignored duplicate app startup request")
            return
        }
        connectivity.start()
        let startedAt = Date()
        let interval = QobuzPerformanceSignposts.begin("AppStartup")
        qobuzLog.notice("lifecycle", "Native app startup started")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performStartup(
                id: startupID,
                startedAt: startedAt,
                onValidateAccount: onValidateAccount,
                onOpenURL: onOpenURL,
                onNotice: onNotice,
                onRequireSettings: onRequireSettings
            )
            QobuzPerformanceSignposts.end(
                interval,
                metadata: "queue=\(queue.items.count) activities=\(downloads.activities.count)"
            )
        }
        startupTask = task
        startupTaskID = startupID
        await task.value
        if startupTaskID == startupID {
            startupTask = nil
            startupTaskID = nil
        }
    }

    private func performStartup(
        id: UUID,
        startedAt: Date,
        onValidateAccount: @escaping @MainActor () async -> Void,
        onOpenURL: @escaping @MainActor (URL) -> Void,
        onNotice: @escaping (String) -> Void,
        onRequireSettings: @escaping () -> Void
    ) async {
        do {
            try await account.load()
        } catch {
            finishStartupFailure(
                id: id,
                startedAt: startedAt,
                message: "Could not load native settings: \(error.localizedDescription)",
                requiresSettings: true,
                error: error,
                onNotice: onNotice,
                onRequireSettings: onRequireSettings
            )
            return
        }
        guard startupGate.isCurrent(id), !Task.isCancelled else { return }
        qobuzLog.info(
            "lifecycle",
            "Startup configuration loaded",
            metadata: [
                "credentialsConfigured": String(account.credentials.isComplete),
                "downloadPath": account.settings.downloadPath,
                "quality": account.settings.quality.rawValue
            ]
        )
        let libraryRoot = account.downloadRoot
        if await library.loadCache(for: libraryRoot) == .rejected {
            guard startupGate.isCurrent(id), !Task.isCancelled else { return }
            qobuzLog.notice(
                "library.cache",
                "No valid archive cache is available; rebuilding from the Library"
            )
            library.refresh(root: libraryRoot, onFailure: onNotice)
        }
        guard startupGate.isCurrent(id), !Task.isCancelled else { return }
        do {
            try await session.restore(root: libraryRoot)
        } catch {
            finishStartupFailure(
                id: id,
                startedAt: startedAt,
                message: "Could not restore the download queue: \(error.localizedDescription)",
                requiresSettings: false,
                error: error,
                onNotice: onNotice,
                onRequireSettings: onRequireSettings
            )
            return
        }
        guard startupGate.isCurrent(id), !Task.isCancelled else { return }
        synchronizeAccount()
        if let selectedID = queue.selectedID,
           let item = queue.items.first(where: { $0.id == selectedID }) {
            loadPreview(item)
        }
        guard let pendingURLs = startupGate.complete(id) else { return }
        pendingURLs.forEach(onOpenURL)
        session.persistNow(reportErrors: false)
        if account.credentials.isComplete {
            accountValidationTask?.cancel()
            accountValidationTask = Task { await onValidateAccount() }
        } else {
            onRequireSettings()
        }
        qobuzLog.notice(
            "lifecycle",
            "Native app startup completed",
            metadata: [
                "queueCount": String(queue.items.count),
                "activityCount": String(downloads.activities.count),
                "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                "bufferedOpenURLs": String(pendingURLs.count)
            ]
        )
    }

    private func finishStartupFailure(
        id: UUID,
        startedAt: Date,
        message: String,
        requiresSettings: Bool,
        error: Error,
        onNotice: (String) -> Void,
        onRequireSettings: () -> Void
    ) {
        guard startupGate.isCurrent(id) else { return }
        startupGate.fail(id)
        connectivity.stop()
        library.cancelRefresh()
        guard !error.isQobuzCancellation else {
            qobuzLog.debug("lifecycle", "Native app startup cancelled and can be retried")
            return
        }
        qobuzLog.critical(
            "lifecycle",
            "Native app startup failed",
            metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))],
            error: error
        )
        onNotice(message)
        if requiresSettings { onRequireSettings() }
    }

    func synchronizeAccount() {
        browse.configure(client: account.client, accountRegion: account.accountRegion)
        linkInbox.configure(client: account.client, accountRegion: account.accountRegion)
    }

    func synchronizeAccountRegion() {
        browse.updateAccountRegion(account.accountRegion)
        linkInbox.updateAccountRegion(account.accountRegion)
    }

    func applyConfigurationChange(_ change: NativeConfigurationChange) -> NativeConfigurationFollowUp {
        if change.downloadRootChanged { library.invalidate() }
        if startupGate.canRetry { return .retryStartup }
        guard change.credentialsChanged else { return .saved }
        synchronizeAccount()
        if let item = queue.selectedItem { loadPreview(item) }
        else { preview.clear() }
        return .validateAccount
    }

    private func loadPreview(_ item: NativeQueueItem) {
        queueOrchestrator.loadPreview(
            item,
            client: account.client,
            unavailabilityMessage: { [weak browse] track in
                browse?.unavailabilityMessage(for: track)
            }
        )
    }

    func prepareForTermination() {
        guard startupGate.state != .terminating else { return }
        startupGate.beginTermination()
        startupTask?.cancel()
        startupTask = nil
        startupTaskID = nil
        accountValidationTask?.cancel()
        accountValidationTask = nil
        account.cancelValidation()
        qobuzLog.notice(
            "lifecycle",
            "App termination preparation started",
            metadata: [
                "activeDownload": String(downloads.isDownloading),
                "queueCount": String(queue.items.count),
                "activityCount": String(downloads.activities.count)
            ]
        )
        session.beginTermination()
        browse.cancelPendingWork()
        linkInbox.cancel()
        preview.cancel()
        library.cancelRefresh()
        connectivity.stop()
        downloads.prepareForTermination()
        session.persistForTermination()
        qobuzLog.notice("lifecycle", "App termination state persisted")
        finalFlush?()
    }
}
