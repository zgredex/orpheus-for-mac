import Foundation

enum QobuzLibraryPruneTransactionCheckpoint: Sendable {
    case stagedOriginals
    case appliedMutation(path: LibraryRelativePath)
    case appliedFinalState
    case verifiedIndex
}

struct QobuzLibraryPruneTransaction {
    typealias FaultInjector = @Sendable (QobuzLibraryPruneTransactionCheckpoint) throws -> Void

    let libraryFiles: LibraryFileSystem
    let injectFault: FaultInjector

    init(
        fileSystem: LibraryFileSystem,
        faultInjector: @escaping FaultInjector = { _ in }
    ) {
        libraryFiles = fileSystem
        injectFault = faultInjector
    }

    func execute(
        plan: QobuzLibraryPrunePlan,
        verify: () async throws -> QobuzArchiveSnapshot
    ) async throws -> QobuzArchiveSnapshot {
        let transaction = LibraryFileTransaction(
            fileSystem: libraryFiles,
            faultInjector: { checkpoint in
                switch checkpoint {
                case .stagedOriginals: try injectFault(.stagedOriginals)
                case .appliedMutation(let index):
                    guard plan.mutations.indices.contains(index) else {
                        throw NativeQobuzError.fileSystem(
                            "The Library prune transaction reported an invalid mutation index."
                        )
                    }
                    try injectFault(.appliedMutation(path: plan.mutations[index].path))
                case .appliedFinalState: try injectFault(.appliedFinalState)
                case .verifiedFinalState: try injectFault(.verifiedIndex)
                }
            }
        )
        let prepared = try await transaction.prepare(
            plan: LibraryFileTransactionPlan(
                operation: "library-prune",
                mutations: try plan.mutations.map(transactionMutation)
            )
        ) {
            let snapshot = try await verify()
            try validate(snapshot, against: plan)
            return snapshot
        }
        var commitStarted = false
        do {
            try transaction.prepareCommit(prepared.token)
            commitStarted = true
            try transaction.finishCommit(prepared.token)
            return prepared.value
        } catch {
            if !commitStarted {
                do {
                    try transaction.rollback(prepared.token)
                } catch let rollbackError {
                    throw NativeQobuzError.fileSystem(
                        "Library prune commit preparation failed: \(error.localizedDescription). "
                            + "Rollback also failed: \(rollbackError.localizedDescription)."
                    )
                }
            }
            throw error
        }
    }

    static func recoverInterruptedTransactions(in fileSystem: LibraryFileSystem) throws {
        try LibraryFileTransaction.recoverInterruptedTransactions(in: fileSystem)
    }

    private func transactionMutation(
        _ mutation: QobuzLibraryFileMutation
    ) throws -> LibraryFileTransactionMutation {
        let expected: LibraryFileExpectedState
        if mutation.originalMetadata != nil, let digest = mutation.originalSHA256 {
            expected = .regularFile(sha256: digest)
        } else if mutation.originalMetadata == nil, mutation.originalSHA256 == nil {
            expected = .absent
        } else {
            throw NativeQobuzError.fileSystem("The Library prune plan has an invalid original state.")
        }
        let final: LibraryFileFinalState
        switch mutation.finalState {
        case .absent: final = .absent
        case .replacement(let data): final = .data(data)
        }
        return LibraryFileTransactionMutation(
            path: mutation.path,
            expectedOriginal: expected,
            finalState: final
        )
    }

    private func validate(
        _ snapshot: QobuzArchiveSnapshot,
        against plan: QobuzLibraryPrunePlan
    ) throws {
        let refreshedTracks = snapshot.tracks.sorted { $0.relativePath < $1.relativePath }
        let hasNewIssues = snapshot.issues.contains {
            !plan.priorIssueKeys.contains(QobuzLibraryPrunePlanner.issueKey($0))
        }
        guard snapshot.rootPath == libraryFiles.rootURL.path,
              refreshedTracks == plan.expectedTracks,
              !hasNewIssues,
              snapshot.collections == plan.expectedCollections else {
            throw NativeQobuzError.fileSystem(
                "The Library index did not match the staged prune result; all changes were rolled back."
            )
        }
    }
}
