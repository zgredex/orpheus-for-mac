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
    private let maintenance: any QobuzLibraryMaintaining

    init(
        account: NativeAccountController,
        library: NativeLibraryController,
        maintenance: any QobuzLibraryMaintaining
    ) {
        self.account = account
        self.library = library
        self.maintenance = maintenance
    }

    var isWorking: Bool { phase != .idle }

    func relocate(to destination: URL, downloadIsActive: Bool) async throws -> String {
        let source = account.downloadRoot
        let snapshot = try availableSnapshot(downloadIsActive: downloadIsActive)
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
            qobuzLog.critical(
                "library.relocation.activation",
                "Verified relocation could not become the active Library; rollback started",
                metadata: [
                    "sourceRoot": source.path,
                    "destinationRoot": destination.path
                ],
                error: error
            )
            _ = try? account.save(
                credentials: account.credentials,
                settings: previousSettings,
                downloadIsActive: false
            )
            _ = try? await maintenance.deleteLibrary(at: destination, snapshot: result.snapshot)
            throw error
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
            qobuzLog.error(
                "library.relocation.cleanup",
                "Relocation succeeded but old managed content could not be fully removed",
                metadata: [
                    "sourceRoot": source.path,
                    "destinationRoot": destination.path
                ],
                error: error
            )
            return "Library relocated and verified. Some managed files remain in the old folder."
        }
    }

    func pruneProblems(downloadIsActive: Bool) async throws -> QobuzLibraryPruneResult {
        let snapshot = try availableSnapshot(downloadIsActive: downloadIsActive)
        phase = .pruning
        defer { phase = .idle }
        let result = try await maintenance.pruneProblems(
            at: account.downloadRoot,
            snapshot: snapshot
        )
        try library.install(result.snapshot, open: library.isOpen)
        return result
    }

    func deleteLibrary(downloadIsActive: Bool) async throws -> QobuzLibraryPruneResult {
        let snapshot = try availableSnapshot(downloadIsActive: downloadIsActive)
        phase = .deleting
        defer { phase = .idle }
        let result = try await maintenance.deleteLibrary(
            at: account.downloadRoot,
            snapshot: snapshot
        )
        try library.install(result.snapshot, open: library.isOpen)
        return result
    }

    private func availableSnapshot(downloadIsActive: Bool) throws -> QobuzArchiveSnapshot {
        guard !downloadIsActive else {
            throw NativeQobuzError.unavailable("Library management is unavailable during a download.")
        }
        guard !isWorking else {
            throw NativeQobuzError.unavailable("Another Library operation is already running.")
        }
        guard let snapshot = library.snapshot,
              snapshot.rootPath == account.downloadRoot.path else {
            throw NativeQobuzError.unavailable("Verify the current Library before managing it.")
        }
        return snapshot
    }
}
