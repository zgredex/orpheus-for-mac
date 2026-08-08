import Foundation
import NativeQobuzCore

/// Commits a completed download into the authoritative Library projection and
/// durable cache. Returning successfully is the completion barrier for Activity.
struct NativeDownloadedLibraryIndexer: Sendable {
    let archiveStore: any NativeArchiveIndexStoring
    let scanner: any QobuzArchiveScanning

    func index(
        root: URL,
        reusing snapshot: QobuzArchiveSnapshot?,
        changedAudioURLs: [URL]
    ) async throws -> QobuzArchiveSnapshot {
        let startedAt = Date()
        let validator = NativeDownloadedLibraryIndexValidator(
            root: root,
            changedAudioURLs: changedAudioURLs
        )
        let indexed = try await scanner.scan(
            root: root,
            reusing: snapshot,
            changedAudioURLs: changedAudioURLs
        )
        try validator.validate(indexed)
        try archiveStore.save(indexed)
        qobuzLog.notice(
            "download.library.index",
            "Downloaded output was committed to the Library index",
            metadata: [
                "downloadRoot": root.path,
                "trackCount": String(indexed.tracks.count),
                "problemCount": String(indexed.problemCount),
                "changedAudioCount": String(changedAudioURLs.count),
                "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
            ]
        )
        return indexed
    }
}

private struct NativeDownloadedLibraryIndexValidator {
    let root: URL
    let changedAudioURLs: [URL]

    func validate(_ snapshot: QobuzArchiveSnapshot) throws {
        let fileSystem = try LibraryFileSystem(
            rootURL: root.standardizedFileURL,
            createIfMissing: false
        )
        guard snapshot.rootPath == fileSystem.rootURL.path else {
            throw NativeQobuzError.invalidResponse(
                "The rebuilt Library index belongs to a different download folder."
            )
        }
        try snapshot.validate()
        guard !changedAudioURLs.isEmpty else {
            throw NativeQobuzError.invalidResponse(
                "Library indexing received no downloaded audio outputs."
            )
        }

        let paths = try changedAudioURLs.map { try fileSystem.relativePath(for: $0) }
        guard Set(paths).count == paths.count else {
            throw NativeQobuzError.invalidResponse(
                "Library indexing received duplicate downloaded audio outputs."
            )
        }
        let tracksByPath = Dictionary(grouping: snapshot.tracks, by: \.relativePath)
        for path in paths {
            guard let metadata = try fileSystem.metadata(at: path) else {
                throw LibraryFileSystemError.missing(path.rawValue)
            }
            if metadata.kind == .symbolicLink {
                throw LibraryFileSystemError.symbolicLink(path.rawValue)
            }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            guard let matches = tracksByPath[path.rawValue],
                  matches.count == 1,
                  matches[0].integrity == .verified,
                  matches[0].isLibraryManaged else {
                throw NativeQobuzError.invalidResponse(
                    "Downloaded output was not indexed exactly once as verified Library-managed audio: \(path.rawValue)"
                )
            }
        }
    }
}
