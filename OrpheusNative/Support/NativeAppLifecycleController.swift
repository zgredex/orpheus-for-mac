import Foundation
import NativeQobuzCore

@MainActor
final class NativeAppLifecycleController {
    private let account: NativeAccountController
    private let browse: NativeBrowseController
    private let queue: NativeQueueController
    private let preview: NativePreviewController
    private let linkInbox: NativeLinkInboxController
    private let library: NativeLibraryController
    private let connectivity: NativeConnectivityController
    private let downloads: NativeDownloadController
    private let session: NativeSessionController
    private var started = false
    private var isTerminating = false

    init(
        account: NativeAccountController,
        browse: NativeBrowseController,
        queue: NativeQueueController,
        preview: NativePreviewController,
        linkInbox: NativeLinkInboxController,
        library: NativeLibraryController,
        connectivity: NativeConnectivityController,
        downloads: NativeDownloadController,
        session: NativeSessionController
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
    }

    func start(
        onLoadPreview: (NativeQueueItem) -> Void,
        onValidateAccount: @escaping () -> Void,
        onNotice: @escaping (String) -> Void,
        onRequireSettings: @escaping () -> Void
    ) async {
        guard !started else {
            qobuzLog.debug("lifecycle", "Ignored duplicate app startup request")
            return
        }
        started = true
        session.activate()
        connectivity.start()
        let startedAt = Date()
        let interval = QobuzPerformanceSignposts.begin("AppStartup")
        defer {
            QobuzPerformanceSignposts.end(
                interval,
                metadata: "queue=\(queue.items.count) activities=\(downloads.activities.count)"
            )
        }
        qobuzLog.notice("lifecycle", "Native app startup started")
        do {
            try await account.load()
            qobuzLog.info(
                "lifecycle",
                "Startup configuration loaded",
                metadata: [
                    "credentialsConfigured": String(account.credentials.isComplete),
                    "downloadPath": account.settings.downloadPath,
                    "quality": account.settings.quality.rawValue
                ]
            )
            let libraryRoot = URL(
                fileURLWithPath: account.settings.downloadPath,
                isDirectory: true
            ).standardizedFileURL
            if await library.loadCache(for: libraryRoot) == .rejected {
                qobuzLog.notice(
                    "library.cache",
                    "No valid archive cache is available; rebuilding from the Library"
                )
                library.refresh(root: libraryRoot) { message in
                    onNotice(message)
                }
            }
            do {
                try await session.restore(root: libraryRoot)
            } catch {
                qobuzLog.error("persistence.session", "Download queue restoration failed", error: error)
                onNotice("Could not restore the download queue: \(error.localizedDescription)")
            }
            synchronizeAccount()
            if let selectedID = queue.selectedID,
               let item = queue.items.first(where: { $0.id == selectedID }) {
                onLoadPreview(item)
            }
            if account.credentials.isComplete {
                onValidateAccount()
            } else {
                onRequireSettings()
            }
            session.persistNow(reportErrors: false)
            qobuzLog.notice(
                "lifecycle",
                "Native app startup completed",
                metadata: [
                    "queueCount": String(queue.items.count),
                    "activityCount": String(downloads.activities.count),
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ]
            )
        } catch {
            qobuzLog.critical(
                "lifecycle",
                "Native app startup failed",
                metadata: ["durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))],
                error: error
            )
            onNotice("Could not load native settings: \(error.localizedDescription)")
            onRequireSettings()
        }
    }

    func synchronizeAccount() {
        browse.configure(client: account.client, accountRegion: account.accountRegion)
        linkInbox.configure(client: account.client, accountRegion: account.accountRegion)
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
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
        linkInbox.cancel()
        preview.cancel()
        library.cancelRefresh()
        connectivity.stop()
        downloads.prepareForTermination()
        session.persistNow(reportErrors: false)
        qobuzLog.notice("lifecycle", "App termination state persisted")
    }
}
