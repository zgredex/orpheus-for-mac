import Foundation

struct QobuzArchiveManifestInspection {
    let tracks: [QobuzArchiveTrack]
    let issues: [QobuzArchiveIssue]
    let reusedChecksums: Int
}

struct QobuzArchiveInspectionContext {
    enum Mode {
        case full
        case incremental

        var failureCategory: String {
            switch self {
            case .full: "library.scan.manifest"
            case .incremental: "library.scan.incremental"
            }
        }

        var failureMessage: String {
            switch self {
            case .full: "Provenance manifest could not be inspected"
            case .incremental: "Changed provenance folder could not be inspected"
            }
        }
    }

    let inspector: QobuzArchiveManifestInspector
    let fileSystem: LibraryFileSystem
    let previousByPath: [String: QobuzArchiveTrack]
    let scanMetadata: [String: String]
    let failureCategory: String
    let failureMessage: String

    init(
        mode: Mode,
        inspector: QobuzArchiveManifestInspector,
        fileSystem: LibraryFileSystem,
        previousByPath: [String: QobuzArchiveTrack],
        scanMetadata: [String: String]
    ) {
        self.inspector = inspector
        self.fileSystem = fileSystem
        self.previousByPath = previousByPath
        self.scanMetadata = scanMetadata
        failureCategory = mode.failureCategory
        failureMessage = mode.failureMessage
    }
}

struct QobuzArchiveScanAccumulator {
    var tracks: [QobuzArchiveTrack]
    var issues: [QobuzArchiveIssue]
    var reusedChecksums = 0

    mutating func inspect(
        _ manifestPath: LibraryRelativePath,
        context: QobuzArchiveInspectionContext
    ) throws {
        do {
            let result = try context.inspector.inspect(
                manifestPath,
                fileSystem: context.fileSystem,
                previousByPath: context.previousByPath,
                scanMetadata: context.scanMetadata
            )
            tracks.append(contentsOf: result.tracks)
            issues.append(contentsOf: result.issues)
            reusedChecksums += result.reusedChecksums
        } catch let error where error.isQobuzCancellation {
            throw NativeQobuzError.cancelled
        } catch {
            qobuzLog.error(
                context.failureCategory,
                context.failureMessage,
                metadata: context.scanMetadata.merging(["manifestPath": manifestPath.rawValue]) { _, new in new },
                error: error
            )
            issues.append(QobuzArchiveIssue(
                relativePath: manifestPath.rawValue,
                message: error.localizedDescription
            ))
        }
    }

    mutating func inspect(
        _ manifestPaths: [LibraryRelativePath],
        context: QobuzArchiveInspectionContext
    ) throws {
        for manifestPath in manifestPaths {
            try Task.checkCancellation()
            try inspect(manifestPath, context: context)
        }
    }

    mutating func snapshot(
        root: URL,
        using inspector: QobuzArchiveManifestInspector,
        fileSystem: LibraryFileSystem,
        scanMetadata: [String: String]
    ) throws -> QobuzArchiveSnapshot {
        tracks.sort { ($0.qobuzAlbumID, $0.relativePath) < ($1.qobuzAlbumID, $1.relativePath) }
        let collections = inspector.loadCollections(
            fileSystem: fileSystem,
            physicalTrackPaths: Set(tracks.map(\.relativePath)),
            issues: &issues,
            scanMetadata: scanMetadata
        )
        let value = QobuzArchiveSnapshot(
            rootPath: root.path,
            tracks: tracks,
            issues: issues,
            collections: collections
        )
        try value.validate()
        return value
    }
}

struct QobuzArchiveManifestInspector {
    private let discovery = QobuzArchiveManifestDiscovery()
    private let integrityEvaluator = QobuzArchiveIntegrityEvaluator()

    func inspect(
        _ manifestPath: LibraryRelativePath,
        fileSystem: LibraryFileSystem,
        previousByPath: [String: QobuzArchiveTrack],
        scanMetadata: [String: String]
    ) throws -> QobuzArchiveManifestInspection {
        qobuzLog.trace(
            "library.scan.manifest",
            "Reading provenance manifest",
            metadata: scanMetadata.merging(["manifestPath": manifestPath.rawValue]) { _, new in new }
        )
        let manifest = try QobuzProvenanceManifestIO.load(from: manifestPath, in: fileSystem)
        let folder = manifestPath.parent
        let checksumPath = try folder.appending(QobuzChecksumManifest.filename)
        let checksumEntries: [String: String]
        do {
            checksumEntries = try QobuzChecksumManifest.load(at: checksumPath, in: fileSystem)
        } catch {
            checksumEntries = [:]
            qobuzLog.warning(
                "library.scan.checksum",
                "Checksum manifest could not be read",
                metadata: scanMetadata.merging(["checksumPath": checksumPath.rawValue]) { _, new in new },
                error: error
            )
        }
        let hasPlaylistManifest = discovery.playlistManifestReferencesFiles(
            in: folder,
            filenames: Set(manifest.files.keys),
            fileSystem: fileSystem
        )
        var tracks: [QobuzArchiveTrack] = []
        var issues: [QobuzArchiveIssue] = []
        var reusedChecksums = 0
        for filename in manifest.files.keys.sorted() {
            try Task.checkCancellation()
            guard QobuzPathSafety.isSafeLeafName(filename), let provenance = manifest.files[filename] else {
                issues.append(QobuzArchiveIssue(
                    relativePath: manifestPath.rawValue,
                    message: "Ignored an unsafe provenance filename."
                ))
                continue
            }
            let audioPath = try folder.appending(filename)
            let relativePath = audioPath.rawValue
            let archiveKind = discovery.resolvedArchiveKind(
                provenance.archiveKind,
                relativePath: relativePath,
                hasPlaylistManifest: hasPlaylistManifest
            )
            let evaluation = integrityEvaluator.evaluate(
                audioPath: audioPath,
                fileSystem: fileSystem,
                provenance: provenance,
                manifestChecksum: checksumEntries[filename],
                previous: previousByPath[relativePath],
                logMetadata: scanMetadata
            )
            if evaluation.reusedChecksum { reusedChecksums += 1 }
            if let issueMessage = evaluation.issueMessage {
                issues.append(QobuzArchiveIssue(relativePath: relativePath, message: issueMessage))
            }
            tracks.append(QobuzArchiveTrack(
                relativePath: relativePath,
                qobuzTrackID: provenance.qobuzTrackID,
                qobuzAlbumID: provenance.qobuzAlbumID,
                formatID: provenance.formatID,
                bitDepth: provenance.bitDepth,
                samplingRate: provenance.samplingRate,
                expectedSHA256: provenance.sha256,
                actualSHA256: evaluation.actualChecksum,
                byteCount: evaluation.byteCount,
                modificationDate: evaluation.modificationDate,
                integrity: evaluation.integrity,
                archiveKind: archiveKind,
                isLibraryManaged: provenance.isLibraryManaged
            ))
            qobuzLog.trace(
                "library.scan.track",
                "Library audio integrity evaluated",
                metadata: scanMetadata.merging([
                    "relativePath": relativePath,
                    "trackID": provenance.qobuzTrackID,
                    "integrity": evaluation.integrity.rawValue,
                    "byteCount": evaluation.byteCount.map(String.init) ?? "unknown"
                ]) { _, new in new }
            )
        }
        return QobuzArchiveManifestInspection(
            tracks: tracks,
            issues: issues,
            reusedChecksums: reusedChecksums
        )
    }

    func loadCollections(
        fileSystem: LibraryFileSystem,
        physicalTrackPaths: Set<String>,
        issues: inout [QobuzArchiveIssue],
        scanMetadata: [String: String]
    ) -> [QobuzLibraryCollectionRecord] {
        do {
            let manifest = try QobuzLibraryManifestIO.load(in: fileSystem)
            try QobuzArchiveSnapshotValidation.validateCollections(
                manifest.collections,
                physicalTrackPaths: physicalTrackPaths
            )
            return manifest.collections
        } catch {
            qobuzLog.error(
                "library.scan.manifest",
                "Library collection manifest could not be loaded",
                metadata: scanMetadata,
                error: error
            )
            issues.append(QobuzArchiveIssue(
                relativePath: QobuzLibraryManifestIO.filename,
                message: error.localizedDescription
            ))
            return []
        }
    }
}
