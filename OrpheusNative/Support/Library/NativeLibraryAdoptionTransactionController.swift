import Foundation
import NativeQobuzCore

struct NativePendingLibraryAdoption {
    let id: String
    let prepared: QobuzPreparedLibraryAdoption

    var result: QobuzLibraryAdoptionResult { prepared.result }
}

struct NativeStagedLibraryAdoption {
    let pending: NativePendingLibraryAdoption
    let previousCache: NativeArchiveIndexLoadResult
}

@MainActor
final class NativeLibraryAdoptionTransactionController {
    private let archiveStore: any NativeArchiveIndexStoring
    private let adopter: any QobuzLibraryAdopting

    init(
        archiveStore: any NativeArchiveIndexStoring,
        adopter: any QobuzLibraryAdopting
    ) {
        self.archiveStore = archiveStore
        self.adopter = adopter
    }

    func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan {
        try await adopter.inspect(root: root)
    }

    func prepare(root: URL) async throws -> QobuzPreparedLibraryAdoption {
        try await adopter.prepare(root: root)
    }

    func stageActivation(_ pending: NativePendingLibraryAdoption) throws -> NativeStagedLibraryAdoption {
        var previousCache: NativeArchiveIndexLoadResult?
        do {
            let loaded = try archiveStore.load()
            previousCache = loaded
            try archiveStore.save(pending.result.snapshot)
            qobuzLog.info(
                "library.adoption.ui",
                "Adopted Library cache staged before configuration activation",
                metadata: [
                    "libraryAdoptionID": pending.id,
                    "candidateRoot": pending.result.plan.root.path
                ]
            )
            return NativeStagedLibraryAdoption(pending: pending, previousCache: loaded)
        } catch {
            var rollback = NativeLibraryAdoptionRollback(primary: error)
            if let previousCache {
                rollback.attempt("archive cache") { try restoreCache(previousCache) }
            }
            rollback.attempt("Library manifest") { try adopter.rollback(pending.prepared) }
            throw rollback.resolvedError()
        }
    }

    func prepareActivationCommit(_ staged: NativeStagedLibraryAdoption) throws {
        try adopter.prepareCommit(staged.pending.prepared)
    }

    func finishActivationCommit(_ staged: NativeStagedLibraryAdoption) throws {
        try adopter.finishCommit(staged.pending.prepared)
    }

    func rollbackActivation(
        _ staged: NativeStagedLibraryAdoption,
        primaryError: Error
    ) throws -> Never {
        var rollback = NativeLibraryAdoptionRollback(primary: primaryError)
        rollback.attempt("Library manifest") { try adopter.rollback(staged.pending.prepared) }
        rollback.attempt("archive cache") { try restoreCache(staged.previousCache) }
        throw rollback.resolvedError()
    }

    private func restoreCache(_ state: NativeArchiveIndexLoadResult) throws {
        switch state {
        case .restored(let snapshot): try archiveStore.save(snapshot)
        case .missing, .rejected: try archiveStore.remove()
        }
    }
}
