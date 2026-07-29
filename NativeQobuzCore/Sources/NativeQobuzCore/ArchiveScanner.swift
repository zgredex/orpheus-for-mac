import Foundation

public protocol QobuzArchiveScanning: Sendable {
    func scan(root: URL) async throws -> QobuzArchiveSnapshot
    func scan(root: URL, reusing previous: QobuzArchiveSnapshot?) async throws -> QobuzArchiveSnapshot
    func scan(
        root: URL,
        reusing previous: QobuzArchiveSnapshot?,
        changedAudioURLs: [URL]
    ) async throws -> QobuzArchiveSnapshot
}

public extension QobuzArchiveScanning {
    func scan(root: URL, reusing previous: QobuzArchiveSnapshot?) async throws -> QobuzArchiveSnapshot {
        try await scan(root: root)
    }

    func scan(
        root: URL,
        reusing previous: QobuzArchiveSnapshot?,
        changedAudioURLs: [URL]
    ) async throws -> QobuzArchiveSnapshot {
        try await scan(root: root, reusing: previous)
    }
}

public struct QobuzArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    private let discovery = QobuzArchiveManifestDiscovery()
    private let inspector = QobuzArchiveManifestInspector()
    private let incrementalScanner = QobuzArchiveIncrementalScanner()

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
        var accumulator = QobuzArchiveScanAccumulator(tracks: [], issues: enumeration.issues)
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
        let inspectionContext = QobuzArchiveInspectionContext(
            mode: .full,
            inspector: inspector,
            fileSystem: fileSystem,
            previousByPath: previousByPath,
            scanMetadata: scanMetadata
        )
        try accumulator.inspect(
            enumeration.paths,
            context: inspectionContext
        )
        let snapshot = try accumulator.snapshot(
            root: root,
            using: inspector,
            fileSystem: fileSystem,
            scanMetadata: scanMetadata
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
                "reusedChecksumCount": String(accumulator.reusedChecksums),
                "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
            ]) { _, new in new }
        )
        return snapshot
    }

    public func scan(
        root: URL,
        reusing previous: QobuzArchiveSnapshot?,
        changedAudioURLs: [URL]
    ) async throws -> QobuzArchiveSnapshot {
        if let previous,
           let incremental = try await incrementalScanner.scan(
               root: root,
               previous: previous,
               changedAudioURLs: changedAudioURLs
           ) {
            return incremental
        }
        return try await scan(root: root, reusing: previous)
    }
}
