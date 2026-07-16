import Foundation
import NativeQobuzCore

/// Commits a completed download into the authoritative Library projection and
/// durable cache. Returning successfully is the completion barrier for Activity.
struct NativeDownloadedLibraryIndexer: Sendable {
    let archiveStore: any NativeArchiveIndexStoring
    let scanner: any QobuzArchiveScanning

    func index(
        root: URL,
        reusing snapshot: QobuzArchiveSnapshot?
    ) async throws -> QobuzArchiveSnapshot {
        let startedAt = Date()
        let indexed = try await scanner.scan(root: root, reusing: snapshot)
        try archiveStore.save(indexed)
        qobuzLog.notice(
            "download.library.index",
            "Downloaded output was committed to the Library index",
            metadata: [
                "downloadRoot": root.path,
                "trackCount": String(indexed.tracks.count),
                "problemCount": String(indexed.problemCount),
                "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
            ]
        )
        return indexed
    }
}
