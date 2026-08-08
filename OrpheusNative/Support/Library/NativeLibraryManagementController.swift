import Foundation
import NativeQobuzCore

enum NativeLibraryMaintenancePhase: Equatable {
    case idle
    case relocating
    case pruning
    case deleting

    var label: String? {
        switch self {
        case .idle: nil
        case .relocating: "Copying, hashing, and verifying the relocated Library…"
        case .pruning: "Pruning problems and rebuilding the Library index…"
        case .deleting: "Deleting Orpheus-managed Library content…"
        }
    }
}

@MainActor
final class NativeLibraryManagementController: ObservableObject {
    @Published private(set) var phase: NativeLibraryMaintenancePhase = .idle

    private let account: NativeAccountController
    private let library: NativeLibraryController
    private let downloads: NativeDownloadController
    private let maintenance: any QobuzLibraryMaintaining

    init(
        account: NativeAccountController,
        library: NativeLibraryController,
        downloads: NativeDownloadController,
        maintenance: any QobuzLibraryMaintaining
    ) {
        self.account = account
        self.library = library
        self.downloads = downloads
        self.maintenance = maintenance
    }

    var isWorking: Bool { phase != .idle }
    var isBlockedByDownloadRecovery: Bool {
        downloads.hasLibraryMutationConflict(at: account.downloadRoot)
    }

    func relocate(to destination: URL) async throws -> String {
        let source = account.downloadRoot
        let snapshot = try availableSnapshot()
        guard !snapshot.tracks.isEmpty else {
            throw NativeQobuzError.unavailable("There is no indexed Library content to relocate.")
        }
        phase = .relocating
        defer { phase = .idle }
        let result = try await maintenance.relocate(
            from: source,
            to: destination,
            snapshot: snapshot
        )
        let previousSettings = account.settings
        do {
            _ = try account.save(
                credentials: account.credentials,
                settings: NativeSettings(
                    downloadPath: destination.standardizedFileURL.path,
                    quality: previousSettings.quality
                ),
                downloadIsActive: false
            )
            try library.install(result.snapshot, open: library.isOpen)
        } catch {
            let activationError = error
            qobuzLog.critical(
                "library.relocation.activation",
                "Verified relocation could not become the active Library; rollback started",
                metadata: [
                    "sourceRoot": source.path,
                    "destinationRoot": destination.path
                ],
                error: error
            )
            do {
                _ = try account.save(
                    credentials: account.credentials,
                    settings: previousSettings,
                    downloadIsActive: false
                )
                try library.install(snapshot, open: library.isOpen)
            } catch {
                qobuzLog.critical(
                    "library.relocation.activation.rollback",
                    "Relocation activation rollback failed; verified destination was preserved",
                    metadata: [
                        "sourceRoot": source.path,
                        "destinationRoot": destination.path,
                        "activationError": activationError.localizedDescription,
                        "rollbackError": error.localizedDescription
                    ],
                    error: error
                )
                throw NativeQobuzError.fileSystem(
                    "Relocation activation failed and could not be rolled back completely. The verified copy was preserved at \(destination.path). Activation: \(activationError.localizedDescription) Rollback: \(error.localizedDescription)"
                )
            }
            do {
                _ = try await maintenance.deleteLibrary(at: destination, snapshot: result.snapshot)
            } catch {
                logRelocationCleanupFailure(
                    event: "library.relocation.activation.cleanup",
                    message: "Rolled-back relocation left its verified destination copy in place",
                    source: source,
                    destination: destination,
                    error: error
                )
            }
            throw activationError
        }

        do {
            let cleanup = try await maintenance.deleteLibrary(at: source, snapshot: snapshot)
            qobuzLog.notice(
                "library.relocation.activation",
                "Relocated Library activated and old managed content removed",
                metadata: [
                    "sourceRoot": source.path,
                    "destinationRoot": destination.path,
                    "copiedFileCount": String(result.copiedFileCount),
                    "copiedByteCount": String(result.copiedByteCount),
                    "removedSourceFileCount": String(cleanup.removedFileCount)
                ]
            )
            return "Library relocated and verified."
        } catch {
            logRelocationCleanupFailure(
                event: "library.relocation.cleanup",
                message: "Relocation succeeded but old managed content could not be fully removed",
                source: source,
                destination: destination,
                error: error
            )
            return "Library relocated and verified. Some managed files remain in the old folder."
        }
    }

    func pruneProblems() async throws -> QobuzLibraryPruneResult {
        let snapshot = try availableSnapshot()
        phase = .pruning
        defer { phase = .idle }
        let result = try await maintenance.pruneProblems(
            at: account.downloadRoot,
            snapshot: snapshot
        )
        try library.install(result.snapshot, open: library.isOpen)
        return result
    }

    func deleteLibrary() async throws -> QobuzLibraryPruneResult {
        let snapshot = try availableSnapshot()
        phase = .deleting
        defer { phase = .idle }
        let result = try await maintenance.deleteLibrary(
            at: account.downloadRoot,
            snapshot: snapshot
        )
        try library.install(result.snapshot, open: library.isOpen)
        return result
    }

    private func availableSnapshot() throws -> QobuzArchiveSnapshot {
        guard !isBlockedByDownloadRecovery else {
            throw NativeQobuzError.unavailable(
                "Library management is unavailable while a download can still write to this Library. Complete or remove its Activity item first."
            )
        }
        guard !isWorking else {
            throw NativeQobuzError.unavailable("Another Library operation is already running.")
        }
        guard !library.isScanning, !library.isPerformingAdoption else {
            throw NativeQobuzError.unavailable("Wait for the current Library operation to finish before managing it.")
        }
        guard let snapshot = library.snapshot,
              snapshot.rootPath == account.downloadRoot.path else {
            throw NativeQobuzError.unavailable("Verify the current Library before managing it.")
        }
        return snapshot
    }

    private func logRelocationCleanupFailure(
        event: String,
        message: String,
        source: URL,
        destination: URL,
        error: Error
    ) {
        qobuzLog.error(
            event,
            message,
            metadata: [
                "sourceRoot": source.path,
                "destinationRoot": destination.path
            ],
            error: error
        )
    }
}
