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

struct NativeArchiveIndexStore: NativeArchiveIndexStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> NativeArchiveIndexLoadResult {
        guard fileManager.fileExists(atPath: paths.archiveIndexURL.path) else {
            qobuzLog.debug("persistence.archive", "No cached archive index exists")
            return .missing
        }
        do {
            let snapshot = try JSONDecoder().decode(
                QobuzArchiveSnapshot.self,
                from: Data(contentsOf: paths.archiveIndexURL)
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
        try fileManager.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(snapshot).write(to: paths.archiveIndexURL, options: .atomic)
        qobuzLog.info(
            "persistence.archive",
            "Archive index cache saved",
            metadata: cacheMetadata(snapshot)
        )
    }

    private func quarantineRejectedCache(cause: Error) throws -> NativeArchiveIndexLoadResult {
        let rejectedURL = paths.applicationSupportRoot.appendingPathComponent(
            "archive-index.rejected-\(UUID().uuidString).json"
        )
        do {
            try fileManager.moveItem(at: paths.archiveIndexURL, to: rejectedURL)
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
