import Foundation

enum LibraryFileTransactionCheckpoint: Sendable {
    case stagedOriginals
    case appliedMutation(index: Int)
    case appliedFinalState
    case verifiedFinalState
}

struct LibraryFileTransactionPrepared<Value> {
    let token: LibraryFileTransactionToken
    let value: Value
}

struct LibraryFileTransaction {
    typealias FaultInjector = @Sendable (LibraryFileTransactionCheckpoint) throws -> Void

    let fileSystem: LibraryFileSystem
    let faultInjector: FaultInjector

    init(
        fileSystem: LibraryFileSystem,
        faultInjector: @escaping FaultInjector = { _ in }
    ) {
        self.fileSystem = fileSystem
        self.faultInjector = faultInjector
    }

    func prepare<Value>(
        plan: LibraryFileTransactionPlan,
        verify: () async throws -> Value
    ) async throws -> LibraryFileTransactionPrepared<Value> {
        let journal = try LibraryFileTransactionJournalBuilder().make(plan)
        let token = LibraryFileTransactionToken(root: fileSystem.rootURL, directory: journal.directory)
        let store = LibraryFileTransactionJournalStore(fileSystem: fileSystem)
        let executor = LibraryFileTransactionExecutor(fileSystem: fileSystem)
        var journalPersisted = false
        do {
            try store.create(journal)
            journalPersisted = true
            try executor.stageOriginals(journal)
            try faultInjector(.stagedOriginals)
            try executor.applyFinalState(
                journal,
                mutations: plan.mutations,
                didApply: { try faultInjector(.appliedMutation(index: $0)) }
            )
            try faultInjector(.appliedFinalState)
            let value = try await verify()
            try faultInjector(.verifiedFinalState)
            var prepared = journal
            prepared.phase = .prepared
            try store.save(prepared)
            LibraryFileTransactionLogger.log(
                .notice,
                "Library file transaction prepared and verified",
                journal: prepared
            )
            return LibraryFileTransactionPrepared(token: token, value: value)
        } catch {
            guard journalPersisted else {
                _ = try? fileSystem.removeEmptyDirectory(journal.directory)
                throw error
            }
            do {
                try rollback(token)
            } catch let rollbackError {
                throw LibraryFileTransactionLogger.rollbackFailure(
                    journal: journal,
                    originalError: error,
                    rollbackError: rollbackError
                )
            }
            throw error
        }
    }

    func prepareCommit(_ token: LibraryFileTransactionToken) throws {
        let store = LibraryFileTransactionJournalStore(fileSystem: fileSystem)
        var journal = try store.load(token)
        guard journal.phase == .prepared || journal.phase == .committing else {
            throw NativeQobuzError.fileSystem("The Library file transaction is not ready to commit.")
        }
        try LibraryFileTransactionExecutor(fileSystem: fileSystem).validateFinalState(journal)
        if journal.phase != .committing {
            journal.phase = .committing
            try store.save(journal)
            LibraryFileTransactionLogger.log(
                .notice,
                "Library file transaction commit marker persisted",
                journal: journal
            )
        }
    }

    func finishCommit(_ token: LibraryFileTransactionToken) throws {
        let store = LibraryFileTransactionJournalStore(fileSystem: fileSystem)
        let journal = try store.load(token)
        guard journal.phase == .committing else {
            throw NativeQobuzError.fileSystem("The Library file transaction commit marker is missing.")
        }
        let executor = LibraryFileTransactionExecutor(fileSystem: fileSystem)
        try executor.validateFinalState(journal)
        try executor.removeQuarantinedOriginals(journal)
        try store.remove(journal)
        LibraryFileTransactionLogger.log(.notice, "Library file transaction committed", journal: journal)
    }

    func rollback(_ token: LibraryFileTransactionToken) throws {
        let store = LibraryFileTransactionJournalStore(fileSystem: fileSystem)
        let journal = try store.load(token)
        try LibraryFileTransactionExecutor(fileSystem: fileSystem).rollback(journal)
        try store.remove(journal)
        LibraryFileTransactionLogger.log(.notice, "Library file transaction rolled back", journal: journal)
    }

    static func recoverInterruptedTransactions(in fileSystem: LibraryFileSystem) throws {
        try LibraryFileTransactionRecovery(fileSystem: fileSystem).recover()
    }
}
