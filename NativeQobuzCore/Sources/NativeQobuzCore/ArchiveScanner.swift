import Foundation

public protocol QobuzArchiveScanning: Sendable {
    func scan(root: URL) async throws -> QobuzArchiveSnapshot
    func scan(root: URL, reusing previous: QobuzArchiveSnapshot?) async throws -> QobuzArchiveSnapshot
}

public extension QobuzArchiveScanning {
    func scan(root: URL, reusing previous: QobuzArchiveSnapshot?) async throws -> QobuzArchiveSnapshot {
        try await scan(root: root)
    }
}

public struct QobuzArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    private let discovery = QobuzArchiveManifestDiscovery()
    private let integrityEvaluator = QobuzArchiveIntegrityEvaluator()

    public init() {}

    public func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        try await scan(root: root, reusing: nil)
    }

    public func scan(
        root: URL,
        reusing previous: QobuzArchiveSnapshot?
    ) async throws -> QobuzArchiveSnapshot {
        let root = root.standardizedFileURL
        let scanID = UUID().uuidString
        let started = Date()
        let scanMetadata = ["libraryScanID": scanID, "downloadRoot": root.path]
        qobuzLog.notice("library.scan", "Library integrity scan started", metadata: scanMetadata)
        let fileSystem: LibraryFileSystem
        do {
            fileSystem = try LibraryFileSystem(rootURL: root, createIfMissing: false)
        } catch LibraryFileSystemError.missing {
            qobuzLog.warning("library.scan", "Library scan found no download folder", metadata: scanMetadata)
            return QobuzArchiveSnapshot(
                rootPath: root.path,
                tracks: [],
                issues: [QobuzArchiveIssue(relativePath: ".", message: "Download folder does not exist yet.")]
            )
        } catch {
            throw NativeQobuzError.fileSystem(error.localizedDescription)
        }

        let enumeration = try discovery.manifestPaths(in: fileSystem)
        var issues = enumeration.issues
        qobuzLog.info(
            "library.scan",
            "Provenance manifests enumerated",
            metadata: scanMetadata.merging([
                "manifestCount": String(enumeration.paths.count),
                "enumerationIssues": String(enumeration.issues.count)
            ]) { _, new in new }
        )

        let reusableTracks = previous?.rootPath == root.path ? (previous?.tracks ?? []) : []
        let previousByPath = Dictionary(reusableTracks.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var tracks: [QobuzArchiveTrack] = []
        var reusedChecksums = 0
        for manifestPath in enumeration.paths {
            try Task.checkCancellation()
            do {
                let result = try inspectManifest(
                    manifestPath,
                    fileSystem: fileSystem,
                    previousByPath: previousByPath,
                    scanMetadata: scanMetadata
                )
                tracks.append(contentsOf: result.tracks)
                issues.append(contentsOf: result.issues)
                reusedChecksums += result.reusedChecksums
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice("library.scan", "Library integrity scan cancelled", metadata: scanMetadata)
                throw NativeQobuzError.cancelled
            } catch {
                qobuzLog.error(
                    "library.scan.manifest",
                    "Provenance manifest could not be inspected",
                    metadata: scanMetadata.merging(["manifestPath": manifestPath.rawValue]) { _, new in new },
                    error: error
                )
                issues.append(QobuzArchiveIssue(
                    relativePath: manifestPath.rawValue,
                    message: error.localizedDescription
                ))
            }
        }

        tracks.sort { ($0.qobuzAlbumID, $0.relativePath) < ($1.qobuzAlbumID, $1.relativePath) }
        let collections = loadCollections(fileSystem: fileSystem, issues: &issues, scanMetadata: scanMetadata)
        let snapshot = QobuzArchiveSnapshot(
            rootPath: root.path,
            tracks: tracks,
            issues: issues,
            collections: collections
        )
        qobuzLog.notice(
            "library.scan",
            "Library integrity scan completed",
            metadata: scanMetadata.merging([
                "trackCount": String(snapshot.tracks.count),
                "verifiedCount": String(snapshot.verifiedCount),
                "problemCount": String(snapshot.problemCount),
                "issueCount": String(snapshot.issues.count),
                "collectionCount": String(snapshot.collections.count),
                "reusedChecksumCount": String(reusedChecksums),
                "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
            ]) { _, new in new }
        )
        return snapshot
    }

    private func inspectManifest(
        _ manifestPath: LibraryRelativePath,
        fileSystem: LibraryFileSystem,
        previousByPath: [String: QobuzArchiveTrack],
        scanMetadata: [String: String]
    ) throws -> (tracks: [QobuzArchiveTrack], issues: [QobuzArchiveIssue], reusedChecksums: Int) {
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
        return (tracks, issues, reusedChecksums)
    }

    private func loadCollections(
        fileSystem: LibraryFileSystem,
        issues: inout [QobuzArchiveIssue],
        scanMetadata: [String: String]
    ) -> [QobuzLibraryCollectionRecord] {
        do {
            let manifest = try QobuzLibraryManifestIO.load(in: fileSystem)
            return manifest.collections.filter { record in
                let paths = [record.relativePath] + record.trackPaths + [record.artworkRelativePath].compactMap { $0 }
                let safe = paths.allSatisfy(QobuzPathSafety.isSafeRelativePath)
                if !safe {
                    issues.append(QobuzArchiveIssue(
                        relativePath: QobuzLibraryManifestIO.filename,
                        message: "Ignored a collection containing an unsafe relative path."
                    ))
                }
                return safe
            }
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
