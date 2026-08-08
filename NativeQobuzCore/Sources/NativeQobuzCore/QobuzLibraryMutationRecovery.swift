import Foundation

/// Resolves every descriptor-relative Library file transaction before a scan.
/// Prepared work rolls back; transactions whose durable commit marker was
/// persisted finish deleting their quarantined originals.
public enum QobuzLibraryMutationRecovery {
    public static func recover(at root: URL) throws {
        let fileSystem: LibraryFileSystem
        do {
            fileSystem = try LibraryFileSystem(
                rootURL: root.standardizedFileURL,
                createIfMissing: false
            )
        } catch LibraryFileSystemError.missing {
            return
        }
        // A missing Library root is harmless, but a missing file referenced by
        // a persisted transaction is not. Keep recovery failures visible so
        // callers cannot discard durable ownership while rollback is incomplete.
        try LibraryFileTransaction.recoverInterruptedTransactions(in: fileSystem)
    }
}
