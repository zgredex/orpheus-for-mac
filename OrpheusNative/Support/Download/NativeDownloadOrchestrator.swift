import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadOrchestrator {
    private let account: NativeAccountController
    private let queue: NativeQueueController
    private let downloads: NativeDownloadController
    private let libraryManagement: NativeLibraryManagementController

    init(
        account: NativeAccountController,
        queue: NativeQueueController,
        downloads: NativeDownloadController,
        libraryManagement: NativeLibraryManagementController
    ) {
        self.account = account
        self.queue = queue
        self.downloads = downloads
        self.libraryManagement = libraryManagement
    }

    var canDownloadSelected: Bool {
        !libraryManagement.isWorking
            && !downloads.isDownloading
            && queue.selectedItem.map(canStartNow) == true
    }

    var canDownloadAll: Bool {
        !libraryManagement.isWorking
            && !downloads.isDownloading
            && queue.items.contains(where: canStartNow)
    }

    func downloadSelected() {
        guard let id = queue.selectedID else { return }
        start(ids: [id])
    }

    func downloadAll() {
        start(ids: queue.items.filter(canStartNow).map(\.id))
    }

    func downloadNext() {
        guard let next = queue.items.first(where: canStartNow) else { return }
        start(ids: [next.id])
    }

    func resume(_ activity: NativeDownloadActivity) {
        recover(activity, action: .resume)
    }

    func retry(_ activity: NativeDownloadActivity) {
        recover(activity, action: .retry)
    }

    private func recover(_ activity: NativeDownloadActivity, action: NativeDownloadRecoveryAction) {
        guard !libraryManagement.isWorking else { return }
        downloads.recover(
            activity,
            action: action,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }

    func repairArchiveTracks(_ tracks: [QobuzArchiveTrack]) {
        guard !libraryManagement.isWorking else { return }
        downloads.repairArchiveTracks(
            tracks,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }

    private func start(ids: [UUID]) {
        guard !libraryManagement.isWorking else { return }
        downloads.start(
            ids: ids,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }

    private func canStartNow(_ item: NativeQueueItem) -> Bool {
        downloads.isStartable(item)
            && (account.credentials.isComplete || downloads.canResumeLibraryIndex(item))
    }
}
