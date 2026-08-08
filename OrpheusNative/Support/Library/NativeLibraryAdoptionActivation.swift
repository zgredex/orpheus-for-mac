import Foundation
import NativeQobuzCore

struct NativeCommittedLibraryAdoption {
    let staged: NativeStagedLibraryAdoption
    let configurationChange: NativeConfigurationChange
    let cleanupPending: Bool
}

struct NativeLibraryAdoptionOutcome {
    fileprivate let committed: NativeCommittedLibraryAdoption
    let notice: String

    var configurationChange: NativeConfigurationChange {
        committed.configurationChange
    }
}

struct NativeLibraryAdoptionRollback {
    let primary: Error
    private var failures: [(component: String, error: Error)] = []

    init(primary: Error) {
        self.primary = primary
    }

    mutating func attempt(_ component: String, operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            failures.append((component, error))
        }
    }

    func resolvedError() -> Error {
        guard !failures.isEmpty else { return primary }
        let details = failures.map {
            "\($0.component): \($0.error.localizedDescription)"
        }.joined(separator: "; ")
        qobuzLog.critical(
            "library.adoption.ui",
            "Library activation failed and automatic rollback was incomplete",
            metadata: [
                "activationError": primary.localizedDescription,
                "rollbackFailures": details
            ]
        )
        return NativeQobuzError.fileSystem(
            "Library activation failed: \(primary.localizedDescription). "
                + "Rollback was incomplete (\(details)). Recovery markers were preserved."
        )
    }
}

@MainActor
struct NativeLibraryAdoptionActivationController {
    let account: NativeAccountController
    let library: NativeLibraryController

    func commit(
        _ pending: NativePendingLibraryAdoption,
        credentials: CredentialDraft,
        quality: QobuzQuality,
        downloadIsActive: Bool
    ) throws -> NativeCommittedLibraryAdoption {
        let staged = try library.stageActivation(pending)
        do {
            try library.prepareActivationCommit(staged)
            let change = try account.save(
                credentials: credentials,
                settings: NativeSettings(
                    downloadPath: pending.result.plan.root.path,
                    quality: quality
                ),
                downloadIsActive: downloadIsActive,
                downloadRootMutationBlocked: false
            )
            let cleanupPending: Bool
            do {
                try library.finishActivationCommit(staged)
                cleanupPending = false
            } catch {
                cleanupPending = true
                qobuzLog.critical(
                    "library.adoption.ui",
                    "Library activation committed but transaction cleanup remains pending",
                    metadata: [
                        "libraryAdoptionID": pending.id,
                        "candidateRoot": pending.result.plan.root.path
                    ],
                    error: error
                )
            }
            return NativeCommittedLibraryAdoption(
                staged: staged,
                configurationChange: change,
                cleanupPending: cleanupPending
            )
        } catch {
            try library.rollbackActivation(staged, primaryError: error)
        }
    }
}

@MainActor
struct NativeLibraryAdoptionCoordinator {
    private let library: NativeLibraryController
    private let activation: NativeLibraryAdoptionActivationController

    init(account: NativeAccountController, library: NativeLibraryController) {
        self.library = library
        activation = NativeLibraryAdoptionActivationController(account: account, library: library)
    }

    func inspect(at root: URL, mutationsBlocked: Bool) async throws -> QobuzLibraryAdoptionPlan {
        try await library.inspectForAdoption(at: root, downloadIsActive: mutationsBlocked)
    }

    func adopt(
        at root: URL,
        draft: SettingsDraft,
        downloadIsActive: Bool,
        mutationsBlocked: Bool
    ) async throws -> NativeLibraryAdoptionOutcome {
        let pending = try await library.prepareAdoption(
            at: root,
            downloadIsActive: mutationsBlocked
        )
        do {
            let committed = try activation.commit(
                pending,
                credentials: draft.credentials,
                quality: draft.quality,
                downloadIsActive: downloadIsActive
            )
            let notice: String
            if committed.cleanupPending {
                notice = "Existing Library adopted. Transaction cleanup will resume automatically."
            } else if pending.result.plan.manifestAction != .none {
                notice = "Existing Library adopted and its index was rebuilt."
            } else {
                notice = "Existing Library adopted and verified."
            }
            return NativeLibraryAdoptionOutcome(committed: committed, notice: notice)
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                "Adopted Library could not become the active download root",
                metadata: ["libraryAdoptionID": pending.id, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func publish(_ outcome: NativeLibraryAdoptionOutcome) {
        library.publishActivation(outcome.committed.staged)
    }
}
