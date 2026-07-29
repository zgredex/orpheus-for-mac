import Foundation
import NativeQobuzCore

enum NativeArchiveIndexLoadResult: Equatable {
    case missing
    case restored(QobuzArchiveSnapshot)
    case rejected
}

protocol NativeArchiveIndexStoring: Sendable {
    func load() throws -> NativeArchiveIndexLoadResult
    func save(_ snapshot: QobuzArchiveSnapshot) throws
}

struct NativeArchiveIndexStore: NativeArchiveIndexStoring, Sendable {
    let paths: NativePaths
    private let files: NativeApplicationSupportFileStore

    init(paths: NativePaths) {
        self.paths = paths
        files = NativeApplicationSupportFileStore(rootURL: paths.applicationSupportRoot)
    }

    func load() throws -> NativeArchiveIndexLoadResult {
        do {
            guard let data = try files.read(.archiveIndex) else {
                qobuzLog.debug("persistence.archive", "No cached archive index exists")
                return .missing
            }
            let snapshot = try JSONDecoder().decode(
                QobuzArchiveSnapshot.self,
                from: data
            )
            qobuzLog.debug(
                "persistence.archive",
                "Cached archive index loaded",
                metadata: cacheMetadata(snapshot)
            )
            return .restored(snapshot)
        } catch {
            return try quarantineRejectedCache(cause: error)
        }
    }

    func save(_ snapshot: QobuzArchiveSnapshot) throws {
        try snapshot.validate()
        try files.write(JSONEncoder.persistence.encode(snapshot), to: .archiveIndex)
        qobuzLog.info(
            "persistence.archive",
            "Archive index cache saved",
            metadata: cacheMetadata(snapshot)
        )
    }

    private func quarantineRejectedCache(cause: Error) throws -> NativeArchiveIndexLoadResult {
        do {
            let rejectedURL = try files.quarantine(
                .archiveIndex,
                rejectedPrefix: "archive-index.rejected"
            )
            qobuzLog.error(
                "persistence.archive",
                "Rejected archive cache was quarantined and will be rebuilt",
                metadata: [
                    "archivePath": paths.archiveIndexURL.path,
                    "rejectedPath": rejectedURL.path
                ],
                error: cause
            )
            return .rejected
        } catch {
            qobuzLog.error(
                "persistence.archive",
                "Invalid archive cache could not be quarantined",
                metadata: ["archivePath": paths.archiveIndexURL.path],
                error: error
            )
            throw cause
        }
    }

    private func cacheMetadata(_ snapshot: QobuzArchiveSnapshot) -> [String: String] {
        [
            "archivePath": paths.archiveIndexURL.path,
            "trackCount": String(snapshot.tracks.count),
            "problemCount": String(snapshot.problemCount),
            "collectionCount": String(snapshot.collections.count)
        ]
    }
}
