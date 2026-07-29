import AppKit
import Foundation
import NativeQobuzCore

@MainActor
struct NativeLibraryRevealController {
    func reveal(
        relativePath: String,
        snapshot: QobuzArchiveSnapshot?,
        allowingRoot: Bool = false
    ) {
        guard let snapshot else { return }
        let root = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true).standardizedFileURL
        guard let target = QobuzPathSafety.containedURL(
            for: relativePath,
            in: root,
            allowingRoot: allowingRoot
        ),
        let existing = NativeSecureRevealResolver().existingItem(target, within: root) else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([existing])
    }
}
