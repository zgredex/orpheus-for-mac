import Foundation
import NativeQobuzCore

@MainActor
final class NativeDownloadOrchestrator {
    private let account: NativeAccountController
    private let queue: NativeQueueController
    private let downloads: NativeDownloadController

    init(
        account: NativeAccountController,
        queue: NativeQueueController,
        downloads: NativeDownloadController
    ) {
        self.account = account
        self.queue = queue
        self.downloads = downloads
    }

    var canDownloadSelected: Bool {
        !downloads.isDownloading
            && queue.selectedItem.map { downloads.isStartable($0) } == true
            && account.credentials.isComplete
    }

    var canDownloadAll: Bool {
        !downloads.isDownloading
            && account.credentials.isComplete
            && queue.items.contains { downloads.isStartable($0) }
    }

    func downloadSelected() {
        guard let id = queue.selectedID else { return }
        start(ids: [id])
    }

    func downloadAll() {
        start(ids: queue.items.filter { downloads.isStartable($0) }.map(\.id))
    }

    func downloadNext() {
        guard let next = queue.items.first(where: { downloads.isStartable($0) }) else { return }
        start(ids: [next.id])
    }

    func resume(_ activity: NativeDownloadActivity) {
        downloads.resume(
            activity,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }

    func retry(_ activity: NativeDownloadActivity) {
        downloads.retry(
            activity,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }

    func repairArchiveTracks(_ tracks: [QobuzArchiveTrack]) {
        downloads.repairArchiveTracks(
            tracks,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }

    private func start(ids: [UUID]) {
        downloads.start(
            ids: ids,
            client: account.client,
            credentialsConfigured: account.credentials.isComplete,
            defaultQuality: account.settings.quality,
            defaultRootPath: account.settings.downloadPath
        )
    }
}
