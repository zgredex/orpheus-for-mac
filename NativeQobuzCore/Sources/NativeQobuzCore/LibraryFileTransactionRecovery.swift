import Foundation

struct LibraryFileTransactionRecovery {
    let fileSystem: LibraryFileSystem

    func recover() throws {
        let store = LibraryFileTransactionJournalStore(fileSystem: fileSystem)
        let transaction = LibraryFileTransaction(fileSystem: fileSystem)
        for candidate in try store.candidates() {
            try requireTransactionDirectory(candidate)
            let token = LibraryFileTransactionToken(
                root: fileSystem.rootURL,
                directory: candidate.path
            )
            let journalPath = try candidate.path.appending(LibraryFileTransactionJournal.filename)
            guard try fileSystem.metadata(at: journalPath) != nil else {
                try store.discardUnpublishedDirectory(candidate.path)
                qobuzLog.warning(
                    "library.file.transaction",
                    "Interrupted transaction journal creation was cleaned up",
                    metadata: ["transactionPath": candidate.path.rawValue]
                )
                continue
            }
            let journal = try store.load(token)
            LibraryFileTransactionLogger.log(
                .warning,
                "Interrupted Library file transaction found",
                journal: journal
            )
            switch journal.phase {
            case .staging, .prepared:
                try transaction.rollback(token)
            case .committing:
                try transaction.finishCommit(token)
            }
        }
    }

    private func requireTransactionDirectory(_ candidate: LibraryDirectoryEntry) throws {
        if candidate.metadata.kind == .symbolicLink {
            throw LibraryFileSystemError.symbolicLink(candidate.path.rawValue)
        }
        guard candidate.metadata.kind == .directory else {
            throw LibraryFileSystemError.notDirectory(candidate.path.rawValue)
        }
    }
}

enum LibraryFileTransactionLogger {
    static func log(
        _ level: QobuzLogLevel,
        _ message: String,
        journal: LibraryFileTransactionJournal
    ) {
        qobuzLog.log(
            level,
            category: "library.file.transaction",
            message,
            metadata: metadata(journal)
        )
    }

    static func rollbackFailure(
        journal: LibraryFileTransactionJournal,
        originalError: Error,
        rollbackError: Error
    ) -> NativeQobuzError {
        qobuzLog.critical(
            "library.file.transaction",
            "Library file transaction failed and automatic rollback could not complete",
            metadata: metadata(journal).merging([
                "originalError": originalError.localizedDescription
            ]) { _, new in new },
            error: rollbackError
        )
        return .fileSystem(
            "Library operation failed: \(originalError.localizedDescription). "
                + "Rollback also failed: \(rollbackError.localizedDescription). "
                + "The recovery journal was preserved."
        )
    }

    private static func metadata(_ journal: LibraryFileTransactionJournal) -> [String: String] {
        [
            "libraryOperation": journal.operation,
            "transactionPath": journal.directory.rawValue,
            "transactionPhase": journal.phase.rawValue,
            "mutationCount": String(journal.entries.count)
        ]
    }
}
