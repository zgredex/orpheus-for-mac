import Foundation

struct QobuzLibraryPruner: Sendable {
    private let scanner: any QobuzArchiveScanning
    private let faultInjector: QobuzLibraryPruneTransaction.FaultInjector

    init(
        scanner: any QobuzArchiveScanning,
        faultInjector: @escaping QobuzLibraryPruneTransaction.FaultInjector = { _ in }
    ) {
        self.scanner = scanner
        self.faultInjector = faultInjector
    }

    func recoverInterruptedTransaction(at root: URL) throws {
        try QobuzLibraryMutationRecovery.recover(at: root)
    }

    func pruneProblems(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try await prune(
            snapshot.tracks.filter { $0.integrity != .verified },
            at: root,
            snapshot: snapshot,
            operation: "problems"
        )
    }

    func deleteLibrary(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try await prune(
            snapshot.tracks,
            at: root,
            snapshot: snapshot,
            operation: "library"
        )
    }

    private func prune(
        _ targets: [QobuzArchiveTrack],
        at rootURL: URL,
        snapshot: QobuzArchiveSnapshot,
        operation: String
    ) async throws -> QobuzLibraryPruneResult {
        let rootURL = rootURL.standardizedFileURL
        guard snapshot.rootPath == rootURL.path else {
            throw NativeQobuzError.fileSystem("The Library index does not belong to the selected folder.")
        }
        guard !targets.isEmpty else {
            return QobuzLibraryPruneResult(
                snapshot: snapshot,
                removedTrackCount: 0,
                removedFileCount: 0,
                reclaimedByteCount: 0
            )
        }

        let operationID = UUID().uuidString
        let logMetadata = [
            "libraryPruneID": operationID,
            "downloadRoot": rootURL.path,
            "operation": operation,
            "targetTrackCount": String(targets.count)
        ]
        qobuzLog.notice("library.prune", "Transactional Library prune started", metadata: logMetadata)
        let fileSystem = try LibraryFileSystem(rootURL: rootURL, createIfMissing: false)
        let plan = try QobuzLibraryPrunePlanner(fileSystem: fileSystem).plan(
            targets: targets,
            snapshot: snapshot
        )
        let transaction = QobuzLibraryPruneTransaction(
            fileSystem: fileSystem,
            faultInjector: faultInjector
        )
        let refreshed = try await transaction.execute(plan: plan) {
            try await scanner.scan(root: rootURL)
        }
        do {
            try removeEmptyAncestors(of: plan.emptyDirectoryCandidates, fileSystem: fileSystem)
        } catch {
            qobuzLog.warning(
                "library.prune.cleanup",
                "Committed Library prune left one or more empty folders",
                metadata: logMetadata,
                error: error
            )
        }

        qobuzLog.notice(
            "library.prune",
            "Library prune committed after manifest and index verification",
            metadata: logMetadata.merging([
                "removedTrackCount": String(targets.count),
                "removedFileCount": String(plan.removedFileCount),
                "reclaimedBytes": String(plan.reclaimedByteCount),
                "remainingTrackCount": String(refreshed.tracks.count),
                "remainingProblemCount": String(refreshed.problemCount)
            ]) { _, new in new }
        )
        return QobuzLibraryPruneResult(
            snapshot: refreshed,
            removedTrackCount: targets.count,
            removedFileCount: plan.removedFileCount,
            reclaimedByteCount: plan.reclaimedByteCount
        )
    }

    private func removeEmptyAncestors(
        of paths: Set<LibraryRelativePath>,
        fileSystem: LibraryFileSystem
    ) throws {
        let directories = Set(paths.flatMap(\.ancestorDirectories)).sorted {
            $0.components.count > $1.components.count
        }
        for directory in directories {
            _ = try fileSystem.removeEmptyDirectory(directory)
        }
    }
}
