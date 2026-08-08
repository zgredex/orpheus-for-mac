import Foundation
import NativeQobuzCore

/// Resolves Activity presentation paths without mutating durable operation
/// history. Completed downloads are projected through the current Library
/// snapshot so a relocation never leaves Reveal pointing at the old root.
struct NativeActivityRevealResolver {
    private let secureResolver = NativeSecureRevealResolver()

    func target(
        for activity: NativeDownloadActivity,
        currentLibrarySnapshot: QobuzArchiveSnapshot?
    ) -> URL? {
        if activity.operation.status == .completed,
           let currentLibrarySnapshot {
            return completedTarget(for: activity.operation, snapshot: currentLibrarySnapshot)
        }
        return recoveryTarget(for: activity.operation)
    }

    private func completedTarget(
        for operation: NativeDownloadOperation,
        snapshot: QobuzArchiveSnapshot
    ) -> URL? {
        let root = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true).standardizedFileURL
        let indexedPaths = Set(snapshot.tracks.map(\.relativePath))
        let oldRoot = operation.downloadRootURL

        for output in operation.outputURLs.reversed() {
            guard let oldRoot,
                  let relativePath = try? QobuzPathSafety.relativePath(
                    of: output,
                    in: oldRoot,
                    allowingRoot: false
                  ),
                  indexedPaths.contains(relativePath),
                  let candidate = QobuzPathSafety.containedURL(
                    for: relativePath,
                    in: root,
                    allowingRoot: false
                  ) else { continue }
            if let existing = secureResolver.existingItem(candidate, within: root) {
                return existing
            }
            if let parent = secureResolver.existingItem(
                candidate.deletingLastPathComponent(),
                within: root
            ) {
                return parent
            }
        }
        return secureResolver.existingItem(root, within: root)
    }

    private func recoveryTarget(for operation: NativeDownloadOperation) -> URL? {
        guard let root = operation.downloadRootURL else { return nil }
        if let output = operation.latestOutputURL,
           let existing = secureResolver.existingItem(output, within: root) {
            return existing
        }
        if let partial = operation.resumablePartial,
           let existing = secureResolver.existingItem(partial.url, within: root) {
            return existing
        }
        if let output = operation.latestOutputURL,
           let folder = secureResolver.existingItem(output.deletingLastPathComponent(), within: root) {
            return folder
        }
        return secureResolver.existingItem(root, within: root)
    }
}
