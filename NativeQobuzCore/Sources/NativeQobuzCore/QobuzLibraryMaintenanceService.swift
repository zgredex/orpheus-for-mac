import Foundation

public struct QobuzLibraryMaintenanceService: QobuzLibraryMaintaining, Sendable {
    private let snapshotGuard: QobuzLibrarySnapshotGuard
    private let relocator: QobuzLibraryRelocator
    private let pruner: QobuzLibraryPruner

    public init(scanner: any QobuzArchiveScanning = QobuzArchiveScanner()) {
        snapshotGuard = QobuzLibrarySnapshotGuard(scanner: scanner)
        relocator = QobuzLibraryRelocator(scanner: scanner)
        pruner = QobuzLibraryPruner(scanner: scanner)
    }

    public func relocate(
        from source: URL,
        to destination: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryRelocationResult {
        try pruner.recoverInterruptedTransaction(at: source)
        let current = try await snapshotGuard.currentSnapshot(at: source, matching: snapshot)
        return try await relocator.relocate(from: source, to: destination, snapshot: current)
    }

    public func pruneProblems(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try pruner.recoverInterruptedTransaction(at: root)
        let current = try await snapshotGuard.currentSnapshot(at: root, matching: snapshot)
        return try await pruner.pruneProblems(at: root, snapshot: current)
    }

    public func deleteLibrary(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try pruner.recoverInterruptedTransaction(at: root)
        let current = try await snapshotGuard.currentSnapshot(at: root, matching: snapshot)
        return try await pruner.deleteLibrary(at: root, snapshot: current)
    }
}
