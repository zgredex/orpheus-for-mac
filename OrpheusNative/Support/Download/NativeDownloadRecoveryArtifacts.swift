import Foundation
import NativeQobuzCore

struct NativeDownloadRecoveryArtifacts: Equatable {
    let root: URL
    let processing: URL
    let partial: URL

    var urls: [URL] { [partial, processing] }
}

/// Derives the only two writable transfer artifacts owned by an operation.
/// Both detection and deletion use this resolver so filename identity cannot
/// drift between recovery paths.
struct NativeDownloadRecoveryArtifactResolver {
    func artifacts(for operation: NativeDownloadOperation) throws -> NativeDownloadRecoveryArtifacts? {
        guard let checkpoint = operation.checkpoint,
              checkpoint.phase.ownsTrackRecoveryArtifacts else {
            guard operation.resumablePartial == nil,
                  operation.checkpoint?.outputURL == nil else {
                throw NativeQobuzError.invalidResponse(
                    "The saved recovery artifact is not owned by a track recovery checkpoint."
                )
            }
            return nil
        }
        guard let root = operation.downloadRootURL,
              let output = operation.latestOutputURL,
              let albumID = checkpoint.albumID,
              let trackID = checkpoint.trackID,
              let format = operation.audioFormat ?? operation.quality?.maximumFormat else {
            throw NativeQobuzError.invalidResponse(
                "The track recovery checkpoint has no exact artifact identity."
            )
        }

        let destination = output.standardizedFileURL
        let processing = QobuzDownloadArtifacts.processingURL(
            for: destination,
            formatID: format.formatID,
            albumID: albumID,
            trackID: trackID
        ).standardizedFileURL
        let partial = QobuzDownloadArtifacts.partialURL(
            for: destination,
            formatID: format.formatID,
            albumID: albumID,
            trackID: trackID
        ).standardizedFileURL
        try validateCheckpointOutput(
            checkpoint,
            destination: destination,
            processing: processing
        )
        if let savedPartial = operation.resumablePartial?.url.standardizedFileURL,
           savedPartial != partial {
            throw NativeQobuzError.invalidResponse(
                "The saved partial path does not match the operation's recovery identity."
            )
        }
        return NativeDownloadRecoveryArtifacts(
            root: root.standardizedFileURL,
            processing: processing,
            partial: partial
        )
    }

    private func validateCheckpointOutput(
        _ checkpoint: QobuzDownloadCheckpoint,
        destination: URL,
        processing: URL
    ) throws {
        let expected: URL = switch checkpoint.phase {
        case .transferringAudio, .writingTags, .validatingAudio: processing
        case .writingProvenance: destination
        case .resolvingCatalog, .resolvingAudio, .writingCollectionAssets, .indexingLibrary, .complete:
            throw NativeQobuzError.invalidResponse(
                "The saved checkpoint phase cannot own track recovery artifacts."
            )
        }
        guard checkpoint.outputURL?.standardizedFileURL == expected else {
            throw NativeQobuzError.invalidResponse(
                "The saved checkpoint output does not match its exact recovery-artifact identity."
            )
        }
    }
}

private extension QobuzDownloadCheckpointPhase {
    var ownsTrackRecoveryArtifacts: Bool {
        switch self {
        case .transferringAudio, .writingTags, .validatingAudio, .writingProvenance: true
        case .resolvingCatalog, .resolvingAudio, .writingCollectionAssets, .indexingLibrary, .complete: false
        }
    }
}

struct NativeDownloadRecoveryContextCleaner {
    private let resolver = NativeDownloadRecoveryArtifactResolver()

    @discardableResult
    func cleanContextOwned(by operation: NativeDownloadOperation) throws -> [URL] {
        if let root = operation.downloadRootURL {
            try QobuzLibraryMutationRecovery.recover(at: root)
        }
        guard let artifacts = try resolver.artifacts(for: operation) else { return [] }
        let fileSystem = try LibraryFileSystem(rootURL: artifacts.root, createIfMissing: false)
        let candidates = try artifacts.urls.map { url in
            (url, try fileSystem.relativePath(for: url))
        }
        var existing: [(URL, LibraryRelativePath)] = []

        // Validate every leaf before deleting any of them. Descriptor-relative
        // traversal rejects symlinks in every ancestor, and leaf symlinks are
        // retained for explicit user inspection rather than unlinked blindly.
        for candidate in candidates {
            guard let metadata = try fileSystem.metadata(at: candidate.1) else { continue }
            if metadata.kind == .symbolicLink {
                throw LibraryFileSystemError.symbolicLink(candidate.1.rawValue)
            }
            guard metadata.kind == .regularFile else {
                throw LibraryFileSystemError.notRegularFile(candidate.1.rawValue)
            }
            existing.append(candidate)
        }
        for candidate in existing {
            try fileSystem.removeFile(candidate.1)
        }
        return existing.map(\.0)
    }
}
