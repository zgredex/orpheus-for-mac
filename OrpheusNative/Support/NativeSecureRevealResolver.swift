import Foundation
import NativeQobuzCore

struct NativeSecureRevealResolver {
    func existingItem(_ candidate: URL, within root: URL) -> URL? {
        do {
            let fileSystem = try LibraryFileSystem(rootURL: root, createIfMissing: false)
            let path = try fileSystem.relativePath(for: candidate, allowingRoot: true)
            guard let metadata = try fileSystem.metadata(at: path),
                  metadata.kind == .regularFile || metadata.kind == .directory else {
                return nil
            }
            return fileSystem.displayURL(for: path)
        } catch {
            return nil
        }
    }
}
