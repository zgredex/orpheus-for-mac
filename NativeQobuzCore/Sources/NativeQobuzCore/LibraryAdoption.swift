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

public protocol QobuzLibraryAdopting: Sendable {
    func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan
    func adopt(root: URL) async throws -> QobuzLibraryAdoptionResult
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
        let unreadableManifest: Bool
        do {
            existingManifest = manifestExists
                ? try QobuzLibraryManifestIO.load(in: fileSystem)
                : nil
            unreadableManifest = false
        } catch {
            existingManifest = nil
            unreadableManifest = true
        }

        let proposed = QobuzLibraryManifest(
            collections: QobuzLibraryCollectionReconciler(fileSystem: fileSystem).reconcile(
                snapshot: snapshot,
                existing: existingManifest?.collections ?? []
            )
        )
        let action: QobuzLibraryManifestAction
        if unreadableManifest {
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
            existingCollectionCount: existingManifest?.collections.count ?? 0,
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

    public func adopt(root: URL) async throws -> QobuzLibraryAdoptionResult {
        let plan = try await inspect(root: root)
        let metadata = [
            "candidateRoot": plan.root.path,
            "manifestAction": plan.manifestAction.rawValue,
            "collectionCount": String(plan.proposedCollectionCount)
        ]
        qobuzLog.notice("library.adoption.apply", "Existing Library adoption started", metadata: metadata)
        if plan.manifestAction != .none {
            let fileSystem = try LibraryFileSystem(rootURL: plan.root, createIfMissing: false)
            try QobuzLibraryManifestIO.save(
                plan.proposedManifest,
                in: fileSystem
            )
        }

        let verifiedSnapshot = try await scanner.scan(root: plan.root)
        guard verifiedSnapshot.collections == plan.proposedManifest.collections else {
            qobuzLog.error(
                "library.adoption.apply",
                "Adopted Library index did not verify after writing",
                metadata: metadata.merging([
                    "verifiedCollectionCount": String(verifiedSnapshot.collections.count)
                ]) { _, new in new }
            )
            throw NativeQobuzError.fileSystem("The rebuilt Library index did not verify after writing.")
        }
        qobuzLog.notice(
            "library.adoption.apply",
            "Existing Library adoption completed and verified",
            metadata: metadata.merging([
                "trackCount": String(verifiedSnapshot.tracks.count),
                "verifiedCount": String(verifiedSnapshot.verifiedCount),
                "problemCount": String(verifiedSnapshot.problemCount)
            ]) { _, new in new }
        )
        return QobuzLibraryAdoptionResult(plan: plan, snapshot: verifiedSnapshot)
    }
}
