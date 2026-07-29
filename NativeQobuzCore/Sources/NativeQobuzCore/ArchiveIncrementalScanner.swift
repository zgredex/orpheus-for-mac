import Foundation

struct QobuzArchiveIncrementalScanner {
    private let inspector = QobuzArchiveManifestInspector()

    func scan(
        root: URL,
        previous: QobuzArchiveSnapshot,
        changedAudioURLs: [URL]
    ) async throws -> QobuzArchiveSnapshot? {
        let root = root.standardizedFileURL
        guard previous.rootPath == root.path, !changedAudioURLs.isEmpty else { return nil }
        let fileSystem = try LibraryFileSystem(rootURL: root, createIfMissing: false)
        let folders = Set(changedAudioURLs.compactMap { url -> LibraryRelativePath? in
            guard let path = try? fileSystem.relativePath(for: url) else { return nil }
            return path.parent
        })
        guard !folders.isEmpty else { return nil }

        let startedAt = Date()
        let scanMetadata = [
            "libraryScanID": UUID().uuidString,
            "downloadRoot": root.path,
            "scanMode": "incremental",
            "changedFolderCount": String(folders.count)
        ]
        qobuzLog.notice(
            "library.scan.incremental",
            "Targeted Library index refresh started",
            metadata: scanMetadata
        )

        let previousByPath = Dictionary(
            uniqueKeysWithValues: previous.tracks.map { ($0.relativePath, $0) }
        )
        var accumulator = QobuzArchiveScanAccumulator(
            tracks: previous.tracks.filter {
                relativeFolder(of: $0.relativePath).map(folders.contains) != true
            },
            issues: previous.issues.filter {
                $0.relativePath == QobuzLibraryManifestIO.filename
                    ? false
                    : relativeFolder(of: $0.relativePath).map(folders.contains) != true
            }
        )
        let inspectionContext = QobuzArchiveInspectionContext(
            mode: .incremental,
            inspector: inspector,
            fileSystem: fileSystem,
            previousByPath: previousByPath,
            scanMetadata: scanMetadata
        )
        for folder in folders.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            let manifestPath = try folder.appending(QobuzProvenanceManifestIO.filename)
            guard let metadata = try fileSystem.metadata(at: manifestPath) else { continue }
            guard metadata.kind == .regularFile else {
                accumulator.issues.append(QobuzArchiveIssue(
                    relativePath: manifestPath.rawValue,
                    message: metadata.kind == .symbolicLink
                        ? "Symbolic link ignored; its target was not opened."
                        : "Expected a regular provenance manifest."
                ))
                continue
            }
            try accumulator.inspect(manifestPath, context: inspectionContext)
        }

        let snapshot = try accumulator.snapshot(
            root: root,
            using: inspector,
            fileSystem: fileSystem,
            scanMetadata: scanMetadata
        )
        let completedMetadata = scanMetadata.merging([
            "trackCount": String(snapshot.tracks.count),
            "problemCount": String(snapshot.problemCount),
            "reusedChecksumCount": String(accumulator.reusedChecksums),
            "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
        ]) { _, new in new }
        qobuzLog.notice(
            "library.scan.incremental",
            "Targeted Library index refresh completed",
            metadata: completedMetadata
        )
        return snapshot
    }

    private func relativeFolder(of relativePath: String) -> LibraryRelativePath? {
        try? LibraryRelativePath(relativePath).parent
    }
}
