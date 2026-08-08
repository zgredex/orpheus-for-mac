import Foundation

struct QobuzTrackCommitTransaction: Sendable {
    private let faultInjector: LibraryFileTransaction.FaultInjector
    private let provenanceStore = QobuzProvenanceStore()

    init(
        faultInjector: @escaping LibraryFileTransaction.FaultInjector = { _ in }
    ) {
        self.faultInjector = faultInjector
    }

    func commit(
        provenance: QobuzFileProvenance,
        expectedSHA256: String,
        stagingURL: URL,
        destinationURL: URL,
        fileSystem: LibraryFileSystem
    ) async throws {
        guard provenance.sha256 == expectedSHA256 else {
            throw NativeQobuzError.invalidResponse(
                "Audio provenance does not match the staged file checksum."
            )
        }
        let staging = try fileSystem.relativePath(for: stagingURL)
        let destination = try fileSystem.relativePath(for: destinationURL)
        let audio = try LibraryFileTransactionMutation.capture(
            path: destination,
            finalState: .stagedFile(path: staging, sha256: expectedSHA256),
            in: fileSystem
        )
        let provenanceMutation = try provenanceStore.mutation(
            recording: provenance,
            for: destinationURL,
            fileSystem: fileSystem
        )
        let transaction = LibraryFileTransaction(
            fileSystem: fileSystem,
            faultInjector: faultInjector
        )
        let prepared = try await transaction.prepare(
            plan: LibraryFileTransactionPlan(
                operation: "download.track-commit",
                mutations: [audio, provenanceMutation]
            )
        ) {
            let installedSHA256 = try MusicFileIntegrity.sha256(of: destination, in: fileSystem)
            guard installedSHA256 == expectedSHA256,
                  try provenanceStore.provenance(
                    for: destinationURL,
                    fileSystem: fileSystem
                  ) == provenance else {
                throw NativeQobuzError.fileSystem(
                    "Installed audio and provenance did not verify as one transaction."
                )
            }
        }
        try transaction.prepareCommit(prepared.token)
        try transaction.finishCommit(prepared.token)
    }
}
