import Foundation

struct QobuzLibraryFileMutation: Sendable {
    enum FinalState: Equatable, Sendable {
        case absent
        case replacement(Data)
    }

    let path: LibraryRelativePath
    let originalMetadata: LibraryFileMetadata?
    let originalSHA256: String?
    let finalState: FinalState
}

struct QobuzLibraryPrunePlan: Sendable {
    let mutations: [QobuzLibraryFileMutation]
    let expectedTracks: [QobuzArchiveTrack]
    let priorIssueKeys: Set<String>
    let expectedCollections: [QobuzLibraryCollectionRecord]

    var removedFileCount: Int {
        mutations.count { mutation in
            mutation.originalMetadata != nil && mutation.finalState.isAbsent
        }
    }

    var reclaimedByteCount: Int64 {
        mutations.reduce(0) { total, mutation in
            guard mutation.finalState.isAbsent else { return total }
            return total + (mutation.originalMetadata?.byteCount ?? 0)
        }
    }

    var emptyDirectoryCandidates: Set<LibraryRelativePath> {
        Set(mutations.compactMap { mutation in
            mutation.finalState.isAbsent ? mutation.path : nil
        })
    }
}

private extension QobuzLibraryFileMutation.FinalState {
    var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }
}

struct QobuzLibraryPrunePlanner {
    let fileSystem: LibraryFileSystem

    func plan(
        targets: [QobuzArchiveTrack],
        snapshot: QobuzArchiveSnapshot
    ) throws -> QobuzLibraryPrunePlan {
        let targetPaths = try Set(targets.map { try LibraryRelativePath($0.relativePath) })
        let targetStrings = Set(targets.map(\.relativePath))
        var mutations: [LibraryRelativePath: QobuzLibraryFileMutation] = [:]

        for path in targetPaths {
            try register(.absent, at: path, in: &mutations)
        }
        try planFolderManifests(removing: targetPaths, mutations: &mutations)

        let libraryManifest = try loadCurrentLibraryManifest(matching: snapshot)
        let removedCollections = libraryManifest.collections.filter {
            !$0.trackPaths.isEmpty && $0.trackPaths.allSatisfy(targetStrings.contains)
        }
        let retainedCollections = libraryManifest.collections.compactMap {
            Self.collection($0, removing: targetStrings)
        }
        let libraryPath = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        let libraryState: QobuzLibraryFileMutation.FinalState = retainedCollections.isEmpty
            ? .absent
            : .replacement(try QobuzLibraryManifestIO.encode(
                QobuzLibraryManifest(collections: retainedCollections)
            ))
        try register(libraryState, at: libraryPath, in: &mutations)

        let playlistReplacements = try QobuzLibraryPlaylistPrunePlanner(
            fileSystem: fileSystem
        ).replacements(
            originalCollections: libraryManifest.collections,
            retainedCollections: retainedCollections,
            removing: targetStrings
        )
        for replacement in playlistReplacements {
            try register(
                .replacement(replacement.contents),
                at: replacement.path,
                in: &mutations
            )
        }

        try planSidecars(
            removedCollections: removedCollections,
            retainedCollections: retainedCollections,
            mutations: &mutations
        )
        return QobuzLibraryPrunePlan(
            mutations: mutations.values.sorted { $0.path.rawValue < $1.path.rawValue },
            expectedTracks: snapshot.tracks
                .filter { !targetStrings.contains($0.relativePath) }
                .sorted { $0.relativePath < $1.relativePath },
            priorIssueKeys: Set(snapshot.issues.map(Self.issueKey)),
            expectedCollections: retainedCollections
        )
    }

    private func planFolderManifests(
        removing paths: Set<LibraryRelativePath>,
        mutations: inout [LibraryRelativePath: QobuzLibraryFileMutation]
    ) throws {
        for folder in Set(paths.map(\.parent)) {
            let names = Set(paths.filter { $0.parent == folder }.compactMap(\.lastComponent))
            let provenancePath = try folder.appending(QobuzProvenanceManifestIO.filename)
            var provenance = try loadProvenance(at: provenancePath)
            names.forEach { provenance.files.removeValue(forKey: $0) }
            try register(
                provenance.files.isEmpty
                    ? .absent
                    : .replacement(try QobuzProvenanceManifestIO.encode(provenance)),
                at: provenancePath,
                in: &mutations
            )

            let checksumPath = try folder.appending(QobuzChecksumManifest.filename)
            var checksums = try loadChecksums(at: checksumPath)
            names.forEach { checksums.removeValue(forKey: $0) }
            try register(
                checksums.isEmpty
                    ? .absent
                    : .replacement(QobuzChecksumManifest.encode(checksums)),
                at: checksumPath,
                in: &mutations
            )
        }
    }

    private func planSidecars(
        removedCollections: [QobuzLibraryCollectionRecord],
        retainedCollections: [QobuzLibraryCollectionRecord],
        mutations: inout [LibraryRelativePath: QobuzLibraryFileMutation]
    ) throws {
        let retainedFolders = try Set(retainedCollections.map(QobuzManagedLibraryAssetPolicy.assetFolder))
        for collection in removedCollections {
            let folder = try QobuzManagedLibraryAssetPolicy.assetFolder(for: collection)
            guard !retainedFolders.contains(folder) else { continue }
            guard let metadata = try fileSystem.metadata(at: folder) else { continue }
            if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(folder.rawValue) }
            guard metadata.kind == .directory else { throw LibraryFileSystemError.notDirectory(folder.rawValue) }
            for entry in try fileSystem.entries(in: folder)
            where QobuzManagedLibraryAssetPolicy.isSidecar(entry.path, for: collection) {
                try register(.absent, at: entry.path, in: &mutations)
            }
        }
    }

    private func loadProvenance(at path: LibraryRelativePath) throws -> QobuzProvenanceManifest {
        try requireRegularFileIfPresent(path)
        return try QobuzProvenanceManifestIO.load(from: path, in: fileSystem)
    }

    private func loadChecksums(at path: LibraryRelativePath) throws -> [String: String] {
        try requireRegularFileIfPresent(path)
        return try QobuzChecksumManifest.load(at: path, in: fileSystem)
    }

    private func loadCurrentLibraryManifest(
        matching snapshot: QobuzArchiveSnapshot
    ) throws -> QobuzLibraryManifest {
        let path = try LibraryRelativePath(QobuzLibraryManifestIO.filename)
        try requireRegularFileIfPresent(path)
        let manifest = try QobuzLibraryManifestIO.load(in: fileSystem)
        guard manifest.collections == snapshot.collections else {
            throw NativeQobuzError.unavailable(
                "The Library collection manifest changed after verification. Verify it again before managing files."
            )
        }
        return manifest
    }

    private func register(
        _ finalState: QobuzLibraryFileMutation.FinalState,
        at path: LibraryRelativePath,
        in mutations: inout [LibraryRelativePath: QobuzLibraryFileMutation]
    ) throws {
        if let existing = mutations[path] {
            guard existing.finalState == finalState else {
                throw NativeQobuzError.fileSystem(
                    "Conflicting Library prune actions were planned for \(path.rawValue)."
                )
            }
            return
        }
        let metadata = try requireRegularFileIfPresent(path)
        guard metadata != nil || !finalState.isAbsent else { return }
        mutations[path] = QobuzLibraryFileMutation(
            path: path,
            originalMetadata: metadata,
            originalSHA256: metadata == nil
                ? nil
                : try MusicFileIntegrity.sha256(of: path, in: fileSystem),
            finalState: finalState
        )
    }

    @discardableResult
    private func requireRegularFileIfPresent(
        _ path: LibraryRelativePath
    ) throws -> LibraryFileMetadata? {
        guard let metadata = try fileSystem.metadata(at: path) else { return nil }
        if metadata.kind == .symbolicLink { throw LibraryFileSystemError.symbolicLink(path.rawValue) }
        guard metadata.kind == .regularFile else {
            throw LibraryFileSystemError.notRegularFile(path.rawValue)
        }
        return metadata
    }

    private static func collection(
        _ value: QobuzLibraryCollectionRecord,
        removing paths: Set<String>
    ) -> QobuzLibraryCollectionRecord? {
        let retainedPaths = value.trackPaths.filter { !paths.contains($0) }
        guard !value.trackPaths.isEmpty ? !retainedPaths.isEmpty : !paths.contains(value.relativePath) else {
            return nil
        }
        return value.replacingTrackPaths(retainedPaths)
    }

    static func issueKey(_ issue: QobuzArchiveIssue) -> String {
        issue.relativePath + "\u{1F}" + issue.message
    }
}
