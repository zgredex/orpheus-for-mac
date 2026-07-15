import Foundation

@MainActor
final class NativeDiagnosticSnapshotBuilder {
    private let account: NativeAccountController
    private let queue: NativeQueueController
    private let downloads: NativeDownloadController
    private let library: NativeLibraryController

    init(
        account: NativeAccountController,
        queue: NativeQueueController,
        downloads: NativeDownloadController,
        library: NativeLibraryController
    ) {
        self.account = account
        self.queue = queue
        self.downloads = downloads
        self.library = library
    }

    func makeSnapshot() -> NativeDiagnosticSnapshot {
        NativeDiagnosticSnapshot(
            downloadQuality: account.settings.quality.displayName,
            downloadRoot: account.settings.downloadPath,
            queue: queue.items.map { item in
                NativeDiagnosticQueueSummary(
                    id: item.id,
                    request: "\(item.request.kindName):\(item.request.id.rawValue)",
                    title: item.title,
                    status: downloads.status(for: item).diagnosticDescription,
                    selectedTracks: queue.preflight(for: item, archiveSnapshot: library.snapshot).selected,
                    quality: item.downloadQuality?.displayName
                )
            },
            activities: downloads.activities.map { activity in
                NativeDiagnosticActivitySummary(
                    id: activity.id,
                    queueID: activity.queueID,
                    title: activity.title,
                    status: downloads.status(for: activity).diagnosticDescription,
                    phase: activity.phase,
                    progress: activity.progress,
                    outputPath: activity.outputURL?.path,
                    warnings: activity.warnings,
                    error: activity.errorMessage
                )
            },
            libraryTrackCount: library.snapshot?.tracks.count ?? 0,
            libraryIssueCount: library.snapshot?.issues.count ?? 0,
            credentialsConfigured: account.credentials.isComplete
        )
    }
}
