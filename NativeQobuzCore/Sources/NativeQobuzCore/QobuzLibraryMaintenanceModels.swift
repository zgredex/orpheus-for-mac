import Foundation

public struct QobuzLibraryRelocationResult: Equatable, Sendable {
    public let snapshot: QobuzArchiveSnapshot
    public let copiedFileCount: Int
    public let copiedByteCount: Int64

    public init(snapshot: QobuzArchiveSnapshot, copiedFileCount: Int, copiedByteCount: Int64) {
        self.snapshot = snapshot
        self.copiedFileCount = copiedFileCount
        self.copiedByteCount = copiedByteCount
    }
}

public struct QobuzLibraryPruneResult: Equatable, Sendable {
    public let snapshot: QobuzArchiveSnapshot
    public let removedTrackCount: Int
    public let removedFileCount: Int
    public let reclaimedByteCount: Int64

    public init(
        snapshot: QobuzArchiveSnapshot,
        removedTrackCount: Int,
        removedFileCount: Int,
        reclaimedByteCount: Int64
    ) {
        self.snapshot = snapshot
        self.removedTrackCount = removedTrackCount
        self.removedFileCount = removedFileCount
        self.reclaimedByteCount = reclaimedByteCount
    }
}

public protocol QobuzLibraryMaintaining: Sendable {
    func relocate(
        from source: URL,
        to destination: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryRelocationResult

    func pruneProblems(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult

    func deleteLibrary(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult
}
