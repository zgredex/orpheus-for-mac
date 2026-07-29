import Foundation
import NativeQobuzCore

struct NativePartialDownloadLocator {
    func artifact(for activity: NativeDownloadActivity, root: URL) -> NativePartialDownload? {
        artifact(for: activity.operation, root: root)
    }

    func artifact(for operation: NativeDownloadOperation, root: URL) -> NativePartialDownload? {
        guard let output = operation.latestOutputURL,
              let format = operation.audioFormat ?? operation.quality?.maximumFormat else { return nil }
        let url = QobuzDownloadArtifacts.partialURL(for: output, formatID: format.formatID)
        guard let fileSystem = try? LibraryFileSystem(rootURL: root, createIfMissing: false),
              let path = try? fileSystem.relativePath(for: url),
              let metadata = try? fileSystem.metadata(at: path),
              metadata.kind == .regularFile,
              metadata.byteCount > 0 else { return nil }
        return NativePartialDownload(url: url, bytes: metadata.byteCount)
    }
}
