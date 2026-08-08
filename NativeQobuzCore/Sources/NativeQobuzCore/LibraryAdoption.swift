import Foundation

public enum QobuzLibraryManifestAction: String, Equatable, Sendable {
    case none
    case create
    case update
    case repair
}

public struct QobuzLibraryAdoptionPlan: Equatable, Sendable {
    public let root: URL
    public let snapshot: QobuzArchiveSnapshot
    public let manifestAction: QobuzLibraryManifestAction
    public let existingCollectionCount: Int
    public let proposedManifest: QobuzLibraryManifest

    public init(
        root: URL,
        snapshot: QobuzArchiveSnapshot,
        manifestAction: QobuzLibraryManifestAction,
        existingCollectionCount: Int,
        proposedManifest: QobuzLibraryManifest
    ) {
        self.root = root
        self.snapshot = snapshot
        self.manifestAction = manifestAction
        self.existingCollectionCount = existingCollectionCount
        self.proposedManifest = proposedManifest
    }

    public var proposedCollectionCount: Int { proposedManifest.collections.count }
}

public struct QobuzLibraryAdoptionResult: Equatable, Sendable {
    public let plan: QobuzLibraryAdoptionPlan
    public let snapshot: QobuzArchiveSnapshot

    public init(plan: QobuzLibraryAdoptionPlan, snapshot: QobuzArchiveSnapshot) {
        self.plan = plan
        self.snapshot = snapshot
    }
}

public struct QobuzPreparedLibraryAdoption: Equatable, Sendable {
    public let result: QobuzLibraryAdoptionResult
    let transaction: LibraryFileTransactionToken?

    public init(result: QobuzLibraryAdoptionResult) {
        self.result = result
        transaction = nil
    }

    init(
        result: QobuzLibraryAdoptionResult,
        transaction: LibraryFileTransactionToken?
    ) {
        self.result = result
        self.transaction = transaction
    }
}

public protocol QobuzLibraryAdopting: Sendable {
    func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan
    func prepare(root: URL) async throws -> QobuzPreparedLibraryAdoption
    func prepareCommit(_ adoption: QobuzPreparedLibraryAdoption) throws
    func finishCommit(_ adoption: QobuzPreparedLibraryAdoption) throws
    func rollback(_ adoption: QobuzPreparedLibraryAdoption) throws
}

/// Reconciles the portable, per-folder provenance records with the logical
/// collection index stored at the Library root. Provenance owns physical file
/// identity; the root manifest owns richer logical collection presentation.
public struct QobuzLibraryAdopter: QobuzLibraryAdopting, @unchecked Sendable {
    private let scanner: any QobuzArchiveScanning

    public init(scanner: any QobuzArchiveScanning = QobuzArchiveScanner()) {
        self.scanner = scanner
    }

    public func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan {
        let root = root.standardizedFileURL
        let adoptionID = UUID().uuidString
        let metadata = ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        qobuzLog.notice("library.adoption.inspect", "Existing Library inspection started", metadata: metadata)

        let fileSystem: LibraryFileSystem
        do {
            fileSystem = try LibraryFileSystem(rootURL: root, createIfMissing: false)
        } catch {
            qobuzLog.warning("library.adoption.inspect", "Library candidate is not a folder", metadata: metadata)
            throw NativeQobuzError.fileSystem("The selected Library folder does not exist.")
        }
        try LibraryFileTransaction.recoverInterruptedTransactions(in: fileSystem)

        let snapshot = try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
            try await scanner.scan(root: root)
        }
        guard !snapshot.tracks.isEmpty else {
            qobuzLog.warning(
                "library.adoption.inspect",
                "Library candidate contains no Orpheus provenance",
                metadata: metadata.merging(["issueCount": String(snapshot.issues.count)]) { _, new in new }
            )
            throw NativeQobuzError.unavailable(
                "No Orpheus provenance records were found in the selected folder."
            )
        }

        let manifestPath = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        let manifestMetadata = try fileSystem.metadata(at: manifestPath)
        if manifestMetadata?.kind == .symbolicLink {
            throw NativeQobuzError.fileSystem("The Library index is a symbolic link and cannot be adopted safely.")
        }
        let manifestExists = manifestMetadata != nil
        let existingManifest: QobuzLibraryManifest?
        var existingCollectionCount = 0
        let invalidManifest: Bool
        do {
            let decoded = manifestExists
                ? try QobuzLibraryManifestIO.load(in: fileSystem)
                : nil
            existingCollectionCount = decoded?.collections.count ?? 0
            if let decoded {
                try QobuzArchiveSnapshotValidation.validateCollectionStructure(decoded.collections)
            }
            existingManifest = decoded
            invalidManifest = false
        } catch {
            existingManifest = nil
            invalidManifest = true
            qobuzLog.warning(
                "library.adoption.inspect",
                "Existing Library index failed semantic validation and will be rebuilt",
                metadata: metadata,
                error: error
            )
        }

        let proposed = QobuzLibraryManifest(
            collections: try QobuzLibraryCollectionReconciler(fileSystem: fileSystem).reconcile(
                snapshot: snapshot,
                existing: existingManifest?.collections ?? []
            )
        )
        try QobuzArchiveSnapshotValidation.validateCollections(
            proposed.collections,
            physicalTrackPaths: Set(snapshot.tracks.map(\.relativePath))
        )
        let action: QobuzLibraryManifestAction
        if invalidManifest {
            action = .repair
        } else if !manifestExists {
            action = .create
        } else if existingManifest != proposed {
            action = .update
        } else {
            action = .none
        }

        let plan = QobuzLibraryAdoptionPlan(
            root: root,
            snapshot: snapshot,
            manifestAction: action,
            existingCollectionCount: existingCollectionCount,
            proposedManifest: proposed
        )
        qobuzLog.notice(
            "library.adoption.inspect",
            "Existing Library inspection completed",
            metadata: metadata.merging([
                "trackCount": String(snapshot.tracks.count),
                "verifiedCount": String(snapshot.verifiedCount),
                "problemCount": String(snapshot.problemCount),
                "existingCollectionCount": String(plan.existingCollectionCount),
                "proposedCollectionCount": String(plan.proposedCollectionCount),
                "manifestAction": action.rawValue
            ]) { _, new in new }
        )
        return plan
    }

    public func prepare(root: URL) async throws -> QobuzPreparedLibraryAdoption {
        let plan = try await inspect(root: root)
        let metadata = [
            "candidateRoot": plan.root.path,
            "manifestAction": plan.manifestAction.rawValue,
            "collectionCount": String(plan.proposedCollectionCount)
        ]
        qobuzLog.notice("library.adoption.apply", "Existing Library adoption started", metadata: metadata)
        let fileSystem = try LibraryFileSystem(rootURL: plan.root, createIfMissing: false)
        let prepared = try await QobuzLibraryAdoptionManifestTransaction(fileSystem: fileSystem).prepare(
            plan: plan
        ) {
            try await scanner.scan(root: plan.root)
        }
        let verifiedSnapshot = prepared.snapshot
        qobuzLog.notice(
            "library.adoption.apply",
            "Existing Library adoption completed and verified",
            metadata: metadata.merging([
                "trackCount": String(verifiedSnapshot.tracks.count),
                "verifiedCount": String(verifiedSnapshot.verifiedCount),
                "problemCount": String(verifiedSnapshot.problemCount)
            ]) { _, new in new }
        )
        return QobuzPreparedLibraryAdoption(
            result: QobuzLibraryAdoptionResult(plan: plan, snapshot: verifiedSnapshot),
            transaction: prepared.token
        )
    }

    public func prepareCommit(_ adoption: QobuzPreparedLibraryAdoption) throws {
        guard let transaction = adoption.transaction else { return }
        try QobuzLibraryAdoptionManifestTransaction(fileSystem: transaction.fileSystem()).prepareCommit(transaction)
    }

    public func finishCommit(_ adoption: QobuzPreparedLibraryAdoption) throws {
        guard let transaction = adoption.transaction else { return }
        try QobuzLibraryAdoptionManifestTransaction(fileSystem: transaction.fileSystem()).finishCommit(transaction)
    }

    public func rollback(_ adoption: QobuzPreparedLibraryAdoption) throws {
        guard let transaction = adoption.transaction else { return }
        try QobuzLibraryAdoptionManifestTransaction(fileSystem: transaction.fileSystem()).rollback(transaction)
    }

    public func adopt(root: URL) async throws -> QobuzLibraryAdoptionResult {
        let prepared = try await prepare(root: root)
        do {
            try prepareCommit(prepared)
        } catch {
            try? rollback(prepared)
            throw error
        }
        try finishCommit(prepared)
        return prepared.result
    }
}
