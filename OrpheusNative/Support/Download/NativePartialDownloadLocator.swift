import Foundation
import NativeQobuzCore

struct NativePartialDownloadLocator {
    private let artifactResolver = NativeDownloadRecoveryArtifactResolver()

    func artifact(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        artifact(for: activity.operation)
    }

    func artifact(for operation: NativeDownloadOperation) -> NativePartialDownload? {
        var attemptedPartialPath: String?
        do {
            guard let artifacts = try artifactResolver.artifacts(for: operation) else { return nil }
            attemptedPartialPath = artifacts.partial.path
            let fileSystem = try LibraryFileSystem(
                rootURL: artifacts.root,
                createIfMissing: false
            )
            let path = try fileSystem.relativePath(for: artifacts.partial)
            guard let metadata = try fileSystem.metadata(at: path) else { return nil }
            if metadata.kind == .symbolicLink {
                throw LibraryFileSystemError.symbolicLink(path.rawValue)
            }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            guard metadata.byteCount > 0 else {
                qobuzLog.debug(
                    "download.recovery.partial",
                    "Zero-byte partial is not resumable",
                    metadata: diagnosticMetadata(operation, partialPath: path.rawValue)
                )
                return nil
            }
            return NativePartialDownload(url: artifacts.partial, bytes: metadata.byteCount)
        } catch {
            qobuzLog.warning(
                "download.recovery.partial",
                "Saved partial could not be inspected safely",
                metadata: diagnosticMetadata(
                    operation,
                    partialPath: attemptedPartialPath ?? operation.resumablePartial?.url.path
                ),
                error: error
            )
            return nil
        }
    }

    private func diagnosticMetadata(
        _ operation: NativeDownloadOperation,
        partialPath: String?
    ) -> [String: String] {
        [
            "queueID": operation.queueID.uuidString,
            "activityID": operation.activityID?.uuidString ?? "none",
            "downloadRoot": operation.downloadRootPath ?? "none",
            "checkpointPhase": operation.checkpoint?.phase.rawValue ?? "none",
            "checkpointOutput": operation.checkpoint?.outputURL?.path ?? "none",
            "latestOutput": operation.latestOutputURL?.path ?? "none",
            "partialPath": partialPath ?? "unresolved"
        ]
    }
}
