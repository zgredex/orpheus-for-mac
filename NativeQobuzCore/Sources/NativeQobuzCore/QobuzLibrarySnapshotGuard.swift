import Foundation

/// Revalidates the exact Library state immediately before a destructive or
/// relocating maintenance operation. UI snapshots are presentation caches and
/// are never authority for filesystem mutation.
struct QobuzLibrarySnapshotGuard: Sendable {
    private let scanner: any QobuzArchiveScanning

    init(scanner: any QobuzArchiveScanning) {
        self.scanner = scanner
    }

    func currentSnapshot(
        at root: URL,
        matching expected: QobuzArchiveSnapshot
    ) async throws -> QobuzArchiveSnapshot {
        let root = root.standardizedFileURL
        guard expected.rootPath == root.path else {
            throw NativeQobuzError.fileSystem(
                "The Library index does not belong to the selected folder."
            )
        }
        let current = try await scanner.scan(root: root)
        guard current.version == expected.version,
              current.rootPath == expected.rootPath,
              current.tracks == expected.tracks,
              current.issues == expected.issues,
              current.collections == expected.collections else {
            qobuzLog.warning(
                "library.maintenance.preflight",
                "Library contents changed after the displayed verification",
                metadata: [
                    "downloadRoot": root.path,
                    "expectedTrackCount": String(expected.tracks.count),
                    "currentTrackCount": String(current.tracks.count),
                    "expectedProblemCount": String(expected.problemCount),
                    "currentProblemCount": String(current.problemCount)
                ]
            )
            throw NativeQobuzError.unavailable(
                "The Library changed after it was verified. Verify it again before managing files."
            )
        }
        return current
    }
}
