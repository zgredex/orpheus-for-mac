import Foundation

struct QobuzLibraryPruner: Sendable {
    private let scanner: any QobuzArchiveScanning

    init(scanner: any QobuzArchiveScanning) {
        self.scanner = scanner
    }

    func pruneProblems(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        let targets = snapshot.tracks.filter { $0.integrity != .verified }
        return try await prune(
            targets,
            at: root,
            snapshot: snapshot,
            operation: "problems"
        )
    }

    func deleteLibrary(
        at root: URL,
        snapshot: QobuzArchiveSnapshot
    ) async throws -> QobuzLibraryPruneResult {
        try await prune(
            snapshot.tracks,
            at: root,
            snapshot: snapshot,
            operation: "library"
        )
    }

    private func prune(
        _ targets: [QobuzArchiveTrack],
        at rootURL: URL,
        snapshot: QobuzArchiveSnapshot,
        operation: String
    ) async throws -> QobuzLibraryPruneResult {
        let rootURL = rootURL.standardizedFileURL
        guard snapshot.rootPath == rootURL.path else {
            throw NativeQobuzError.fileSystem("The Library index does not belong to the selected folder.")
        }
        guard !targets.isEmpty else {
            return QobuzLibraryPruneResult(
                snapshot: snapshot,
                removedTrackCount: 0,
                removedFileCount: 0,
                reclaimedByteCount: 0
            )
        }
        let operationID = UUID().uuidString
        let logMetadata = [
            "libraryPruneID": operationID,
            "downloadRoot": rootURL.path,
            "operation": operation,
            "targetTrackCount": String(targets.count)
        ]
        qobuzLog.notice("library.prune", "Library prune started", metadata: logMetadata)
        let fileSystem = try LibraryFileSystem(rootURL: rootURL, createIfMissing: false)
        let targetPaths = try Set(targets.map { try LibraryRelativePath($0.relativePath) })
        try preflight(
            targetPaths: targetPaths,
            targets: targets,
            snapshot: snapshot,
            fileSystem: fileSystem
        )
        var removedFiles = 0
        var reclaimedBytes: Int64 = 0

        for path in targetPaths.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            guard let metadata = try fileSystem.metadata(at: path) else { continue }
            if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            try fileSystem.removeFile(path)
            removedFiles += 1
            reclaimedBytes += metadata.byteCount
            qobuzLog.info(
                "library.prune.file",
                "Managed audio file removed",
                metadata: logMetadata.merging([
                    "assetPath": path.rawValue,
                    "assetBytes": String(metadata.byteCount)
                ]) { _, new in new }
            )
        }

        try updateFolderManifests(
            removing: targetPaths,
            fileSystem: fileSystem,
            logMetadata: logMetadata,
            removedFiles: &removedFiles,
            reclaimedBytes: &reclaimedBytes
        )
        let removedCollections = try updateLibraryManifest(
            removing: Set(targets.map(\.relativePath)),
            snapshot: snapshot,
            fileSystem: fileSystem
        )
        let removedSidecars = try removeUnreferencedSidecars(
            for: removedCollections,
            retainedCollections: snapshot.collections.filter { !removedCollections.contains($0) },
            fileSystem: fileSystem,
            removedFiles: &removedFiles,
            reclaimedBytes: &reclaimedBytes
        )
        try removeEmptyAncestors(of: targetPaths.union(removedSidecars), fileSystem: fileSystem)

        let refreshed = try await scanner.scan(root: rootURL)
        qobuzLog.notice(
            "library.prune",
            "Library prune completed and index verified",
            metadata: logMetadata.merging([
                "removedTrackCount": String(targets.count),
                "removedFileCount": String(removedFiles),
                "reclaimedBytes": String(reclaimedBytes),
                "remainingTrackCount": String(refreshed.tracks.count),
                "remainingProblemCount": String(refreshed.problemCount)
            ]) { _, new in new }
        )
        return QobuzLibraryPruneResult(
            snapshot: refreshed,
            removedTrackCount: targets.count,
            removedFileCount: removedFiles,
            reclaimedByteCount: reclaimedBytes
        )
    }

    private func preflight(
        targetPaths: Set<LibraryRelativePath>,
        targets: [QobuzArchiveTrack],
        snapshot: QobuzArchiveSnapshot,
        fileSystem: LibraryFileSystem
    ) throws {
        for path in targetPaths {
            try requireRegularFileIfPresent(path, fileSystem: fileSystem)
        }
        for folder in Set(targetPaths.map(\.parent)) {
            let provenance = try folder.appending(QobuzProvenanceManifestIO.filename)
            try requireRegularFileIfPresent(provenance, fileSystem: fileSystem)
            _ = try QobuzProvenanceManifestIO.load(from: provenance, in: fileSystem)
            let checksums = try folder.appending(QobuzChecksumManifest.filename)
            try requireRegularFileIfPresent(checksums, fileSystem: fileSystem)
            _ = try QobuzChecksumManifest.load(at: checksums, in: fileSystem)
        }
        let libraryManifest = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        try requireRegularFileIfPresent(libraryManifest, fileSystem: fileSystem)
        _ = try QobuzLibraryManifestIO.load(in: fileSystem)

        let targetStrings = Set(targets.map(\.relativePath))
        let removedCollections = snapshot.collections.filter {
            !$0.trackPaths.isEmpty && $0.trackPaths.allSatisfy(targetStrings.contains)
        }
        let retainedFolders = Set(snapshot.collections.filter { !removedCollections.contains($0) }.map(\.relativePath))
        for collection in removedCollections where !retainedFolders.contains(collection.relativePath) {
            let folder = try LibraryRelativePath(collection.relativePath)
            guard try fileSystem.metadata(at: folder)?.kind == .directory else { continue }
            for entry in try fileSystem.entries(in: folder)
            where QobuzManagedLibraryAssetPolicy.isSidecar(entry.path) {
                try requireRegularFileIfPresent(entry.path, fileSystem: fileSystem)
            }
        }
    }

    private func requireRegularFileIfPresent(
        _ path: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) throws {
        guard let metadata = try fileSystem.metadata(at: path) else { return }
        if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
        guard metadata.kind == .regularFile else {
            throw LibraryFileSystemError.notRegularFile(path.rawValue)
        }
    }

    private func updateFolderManifests(
        removing paths: Set<LibraryRelativePath>,
        fileSystem: LibraryFileSystem,
        logMetadata: [String: String],
        removedFiles: inout Int,
        reclaimedBytes: inout Int64
    ) throws {
        for folder in Set(paths.map(\.parent)) {
            let names = Set(paths.filter { $0.parent == folder }.compactMap(\.lastComponent))
            let provenancePath = try folder.appending(QobuzProvenanceManifestIO.filename)
            var provenance = try QobuzProvenanceManifestIO.load(from: provenancePath, in: fileSystem)
            names.forEach { provenance.files.removeValue(forKey: $0) }
            try saveOrRemove(
                provenance.files.isEmpty ? nil : QobuzProvenanceManifestIO.encode(provenance),
                at: provenancePath,
                fileSystem: fileSystem,
                removedFiles: &removedFiles,
                reclaimedBytes: &reclaimedBytes
            )

            let checksumPath = try folder.appending(QobuzChecksumManifest.filename)
            var checksums = try QobuzChecksumManifest.load(at: checksumPath, in: fileSystem)
            names.forEach { checksums.removeValue(forKey: $0) }
            try saveOrRemove(
                checksums.isEmpty ? nil : QobuzChecksumManifest.encode(checksums),
                at: checksumPath,
                fileSystem: fileSystem,
                removedFiles: &removedFiles,
                reclaimedBytes: &reclaimedBytes
            )
            qobuzLog.debug(
                "library.prune.manifest",
                "Folder manifests reconciled",
                metadata: logMetadata.merging([
                    "folderPath": folder.rawValue,
                    "removedEntryCount": String(names.count)
                ]) { _, new in new }
            )
        }
    }

    private func updateLibraryManifest(
        removing paths: Set<String>,
        snapshot: QobuzArchiveSnapshot,
        fileSystem: LibraryFileSystem
    ) throws -> [QobuzLibraryCollectionRecord] {
        let removed = snapshot.collections.filter {
            !$0.trackPaths.isEmpty && $0.trackPaths.allSatisfy(paths.contains)
        }
        let retained = snapshot.collections.compactMap {
            Self.collection($0, removing: paths)
        }
        let path = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        if retained.isEmpty {
            try fileSystem.removeFile(path, ifPresent: true)
        } else {
            try QobuzLibraryManifestIO.save(
                QobuzLibraryManifest(collections: retained),
                in: fileSystem
            )
        }
        return removed
    }

    private static func collection(
        _ value: QobuzLibraryCollectionRecord,
        removing paths: Set<String>
    ) -> QobuzLibraryCollectionRecord? {
        let retainedPaths = value.trackPaths.filter { !paths.contains($0) }
        guard !value.trackPaths.isEmpty ? !retainedPaths.isEmpty : !paths.contains(value.relativePath) else {
            return nil
        }
        return QobuzLibraryCollectionRecord(
            id: value.id,
            kind: value.kind,
            qobuzID: value.qobuzID,
            title: value.title,
            subtitle: value.subtitle,
            relativePath: value.relativePath,
            trackPaths: retainedPaths,
            artworkRelativePath: value.artworkRelativePath,
            collectionDescription: value.collectionDescription,
            owner: value.owner,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            duration: value.duration,
            sourceTrackCount: value.sourceTrackCount
        )
    }

    private func removeUnreferencedSidecars(
        for removedCollections: [QobuzLibraryCollectionRecord],
        retainedCollections: [QobuzLibraryCollectionRecord],
        fileSystem: LibraryFileSystem,
        removedFiles: inout Int,
        reclaimedBytes: inout Int64
    ) throws -> Set<LibraryRelativePath> {
        let retainedFolders = Set(retainedCollections.map(\.relativePath))
        var removedPaths = Set<LibraryRelativePath>()
        for collection in removedCollections where !retainedFolders.contains(collection.relativePath) {
            let folder = try LibraryRelativePath(collection.relativePath)
            guard try fileSystem.metadata(at: folder)?.kind == .directory else { continue }
            for entry in try fileSystem.entries(in: folder)
            where QobuzManagedLibraryAssetPolicy.isSidecar(entry.path) {
                try requireRegularFileIfPresent(entry.path, fileSystem: fileSystem)
                try fileSystem.removeFile(entry.path)
                removedFiles += 1
                reclaimedBytes += entry.metadata.byteCount
                removedPaths.insert(entry.path)
            }
        }
        return removedPaths
    }

    private func saveOrRemove(
        _ data: Data?,
        at path: LibraryRelativePath,
        fileSystem: LibraryFileSystem,
        removedFiles: inout Int,
        reclaimedBytes: inout Int64
    ) throws {
        if let data {
            try fileSystem.writeAtomically(data, to: path)
        } else if let metadata = try fileSystem.metadata(at: path) {
            try fileSystem.removeFile(path)
            removedFiles += 1
            reclaimedBytes += metadata.byteCount
        }
    }

    private func removeEmptyAncestors(
        of paths: Set<LibraryRelativePath>,
        fileSystem: LibraryFileSystem
    ) throws {
        let directories = Set(paths.flatMap(\.ancestorDirectories)).sorted {
            $0.components.count > $1.components.count
        }
        for directory in directories {
            _ = try fileSystem.removeEmptyDirectory(directory)
        }
    }
}
