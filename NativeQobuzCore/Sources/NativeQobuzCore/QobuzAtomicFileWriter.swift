import Foundation

struct QobuzAtomicFileWriter: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func write(_ data: Data, to destination: URL) throws {
        var temporary: URL?
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
            temporary = staging
            try data.write(to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            if let temporary {
                do { try fileManager.removeItem(at: temporary) }
                catch {
                    qobuzLog.warning(
                        "asset.filesystem",
                        "Could not remove failed asset staging file",
                        metadata: ["stagingPath": temporary.path],
                        error: error
                    )
                }
            }
            qobuzLog.error(
                "asset.filesystem",
                "Atomic asset write failed",
                metadata: ["destinationPath": destination.path],
                error: error
            )
            throw NativeQobuzError.fileSystem(error.localizedDescription)
        }
    }
}
