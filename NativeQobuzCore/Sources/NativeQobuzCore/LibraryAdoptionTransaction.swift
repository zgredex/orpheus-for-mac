import Foundation

struct QobuzPreparedAdoptionManifest {
    let snapshot: QobuzArchiveSnapshot
    let token: LibraryFileTransactionToken?
}

struct QobuzLibraryAdoptionManifestTransaction {
    let fileSystem: LibraryFileSystem

    func prepare(
        plan: QobuzLibraryAdoptionPlan,
        verify: () async throws -> QobuzArchiveSnapshot
    ) async throws -> QobuzPreparedAdoptionManifest {
        let data = try QobuzLibraryManifestIO.encode(plan.proposedManifest)
        try validateProposedManifest(plan.proposedManifest, against: plan.snapshot)
        guard plan.manifestAction != .none else {
            let snapshot = try await verify()
            try validate(snapshot, against: plan.proposedManifest)
            return QobuzPreparedAdoptionManifest(snapshot: snapshot, token: nil)
        }
        let path = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        let mutation = try LibraryFileTransactionMutation.capture(
            path: path,
            finalState: .data(data),
            in: fileSystem
        )
        let prepared = try await LibraryFileTransaction(fileSystem: fileSystem).prepare(
            plan: LibraryFileTransactionPlan(
                operation: "library-adoption",
                mutations: [mutation]
            )
        ) {
            let snapshot = try await verify()
            try validate(snapshot, against: plan.proposedManifest)
            return snapshot
        }
        return QobuzPreparedAdoptionManifest(snapshot: prepared.value, token: prepared.token)
    }

    func prepareCommit(_ token: LibraryFileTransactionToken) throws {
        try LibraryFileTransaction(fileSystem: fileSystem).prepareCommit(token)
    }

    func finishCommit(_ token: LibraryFileTransactionToken) throws {
        try LibraryFileTransaction(fileSystem: fileSystem).finishCommit(token)
    }

    func rollback(_ token: LibraryFileTransactionToken) throws {
        try LibraryFileTransaction(fileSystem: fileSystem).rollback(token)
    }

    private func validateProposedManifest(
        _ manifest: QobuzLibraryManifest,
        against snapshot: QobuzArchiveSnapshot
    ) throws {
        guard manifest.version == 1 else {
            throw NativeQobuzError.invalidResponse("Unsupported proposed Library manifest version.")
        }
        try QobuzArchiveSnapshotValidation.validateCollections(
            manifest.collections,
            physicalTrackPaths: Set(snapshot.tracks.map(\.relativePath))
        )
    }

    private func validate(
        _ snapshot: QobuzArchiveSnapshot,
        against manifest: QobuzLibraryManifest
    ) throws {
        try snapshot.validate()
        guard snapshot.rootPath == fileSystem.rootURL.path,
              snapshot.collections == manifest.collections else {
            throw NativeQobuzError.fileSystem(
                "The rebuilt Library index did not verify; the original manifest was restored."
            )
        }
    }
}
