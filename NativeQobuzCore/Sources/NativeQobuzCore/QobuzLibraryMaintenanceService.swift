import Foundation

public struct QobuzLibraryMaintenanceService: QobuzLibraryMaintaining, Sendable {
    private let relocator: QobuzLibraryRelocator
    private let pruner: QobuzLibraryPruner

    public init(scanner: any QobuzArchiveScanning = QobuzArchiveScanner()) {
        relocator = QobuzLibraryRelocator(scanner: scanner)
        pruner = QobuzLibraryPruner(scanner: scanner)
    }

    public func relocate(
        from source: URL,
        to destination: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryRelocationResult {
        try await relocator.relocate(from: source, to: destination, snapshot: snapshot)
    }

    public func pruneProblems(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try await pruner.pruneProblems(at: root, snapshot: snapshot)
    }

    public func deleteLibrary(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try await pruner.deleteLibrary(at: root, snapshot: snapshot)
    }
}
