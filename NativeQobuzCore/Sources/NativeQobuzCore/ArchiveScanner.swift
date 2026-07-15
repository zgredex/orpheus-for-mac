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
    private let fileManager: FileManager
    private let discovery: QobuzArchiveManifestDiscovery
    private let integrityEvaluator: QobuzArchiveIntegrityEvaluator

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        discovery = QobuzArchiveManifestDiscovery(fileManager: fileManager)
        integrityEvaluator = QobuzArchiveIntegrityEvaluator(fileManager: fileManager)
    }

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
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            qobuzLog.warning("library.scan", "Library scan found no download folder", metadata: scanMetadata)
            return QobuzArchiveSnapshot(
                rootPath: root.path,
                tracks: [],
                issues: [QobuzArchiveIssue(relativePath: ".", message: "Download folder does not exist yet.")]
            )
        }

        let enumeration = try discovery.manifestURLs(in: root)
        var issues = enumeration.issues
        qobuzLog.info(
            "library.scan",
            "Provenance manifests enumerated",
            metadata: scanMetadata.merging([
                "manifestCount": String(enumeration.urls.count),
                "enumerationIssues": String(enumeration.issues.count)
            ]) { _, new in new }
        )

        let reusableTracks = previous?.rootPath == root.path ? (previous?.tracks ?? []) : []
        let previousByPath = Dictionary(uniqueKeysWithValues: reusableTracks.map { ($0.relativePath, $0) })
        var tracks: [QobuzArchiveTrack] = []
        var reusedChecksums = 0
        for manifestURL in enumeration.urls {
            try Task.checkCancellation()
            let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            do {
                let result = try inspectManifest(
                    manifestURL,
                    root: root,
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
                    metadata: scanMetadata.merging(["manifestPath": manifestURL.path]) { _, new in new },
                    error: error
                )
                issues.append(QobuzArchiveIssue(
                    relativePath: QobuzPathSafety.relativePathOrLastComponent(
                        of: manifestURL,
                        in: root,
                        allowingRoot: true
                    ),
                    message: error.localizedDescription
                ))
            }
        }

        tracks.sort { ($0.qobuzAlbumID, $0.relativePath) < ($1.qobuzAlbumID, $1.relativePath) }
        let collections = loadCollections(root: root, issues: &issues, scanMetadata: scanMetadata)
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
        _ manifestURL: URL,
        root: URL,
        previousByPath: [String: QobuzArchiveTrack],
        scanMetadata: [String: String]
    ) throws -> (tracks: [QobuzArchiveTrack], issues: [QobuzArchiveIssue], reusedChecksums: Int) {
        qobuzLog.trace(
            "library.scan.manifest",
            "Reading provenance manifest",
            metadata: scanMetadata.merging(["manifestPath": manifestURL.path]) { _, new in new }
        )
        let manifest = try QobuzProvenanceManifestIO.load(from: manifestURL, fileManager: fileManager)
        let folder = manifestURL.deletingLastPathComponent()
        let checksumURL = folder.appendingPathComponent(QobuzChecksumManifest.filename)
        let checksumEntries: [String: String]
        do {
            checksumEntries = try QobuzChecksumManifest.load(at: checksumURL, fileManager: fileManager)
        } catch {
            checksumEntries = [:]
            qobuzLog.warning(
                "library.scan.checksum",
                "Checksum manifest could not be read",
                metadata: scanMetadata.merging(["checksumPath": checksumURL.path]) { _, new in new },
                error: error
            )
        }
        let hasPlaylistManifest = discovery.playlistManifestReferencesFiles(
            in: folder,
            filenames: Set(manifest.files.keys)
        )
        var tracks: [QobuzArchiveTrack] = []
        var issues: [QobuzArchiveIssue] = []
        var reusedChecksums = 0
        for filename in manifest.files.keys.sorted() {
            try Task.checkCancellation()
            guard QobuzPathSafety.isSafeLeafName(filename), let provenance = manifest.files[filename] else {
                issues.append(QobuzArchiveIssue(
                    relativePath: QobuzPathSafety.relativePathOrLastComponent(
                        of: manifestURL,
                        in: root,
                        allowingRoot: true
                    ),
                    message: "Ignored an unsafe provenance filename."
                ))
                continue
            }
            let audioURL = folder.appendingPathComponent(filename).standardizedFileURL
            let relativePath = QobuzPathSafety.relativePathOrLastComponent(
                of: audioURL,
                in: root,
                allowingRoot: true
            )
            let archiveKind = discovery.resolvedArchiveKind(
                provenance.archiveKind,
                relativePath: relativePath,
                hasPlaylistManifest: hasPlaylistManifest
            )
            let evaluation = integrityEvaluator.evaluate(
                audioURL: audioURL,
                relativePath: relativePath,
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
        root: URL,
        issues: inout [QobuzArchiveIssue],
        scanMetadata: [String: String]
    ) -> [QobuzLibraryCollectionRecord] {
        do {
            let manifest = try QobuzLibraryManifestIO.load(at: root, fileManager: fileManager)
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
