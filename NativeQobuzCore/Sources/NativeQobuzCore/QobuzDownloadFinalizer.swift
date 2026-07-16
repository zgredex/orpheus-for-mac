import Foundation

struct QobuzDownloadFinalizer: Sendable {
    private let assetWriter: QobuzCollectionAssetWriter

    init(assetWriter: QobuzCollectionAssetWriter) {
        self.assetWriter = assetWriter
    }

    func finalize(
        plan: QobuzDownloadPlan,
        configuration: QobuzDownloadConfiguration,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        continuation: QobuzDownloadContinuation
    ) async throws {
        try await writeBooklets(state: state, fileSystem: fileSystem, continuation: continuation)
        try Task.checkCancellation()
        writeDescriptions(state: state, fileSystem: fileSystem, continuation: continuation)
        try Task.checkCancellation()
        writePlaylist(plan: plan, fileSystem: fileSystem, state: state, continuation: continuation)
        try Task.checkCancellation()
        writeChecksums(state: state, fileSystem: fileSystem, continuation: continuation)
        try Task.checkCancellation()
        try await writePlaylistMetadata(plan: plan, fileSystem: fileSystem, continuation: continuation)
        guard configuration.repairTarget == nil else { return }
        try Task.checkCancellation()
        updateLibrary(plan: plan, fileSystem: fileSystem, state: state, continuation: continuation)
    }

    private func writeBooklets(
        state: QobuzDownloadOperationState,
        fileSystem: LibraryFileSystem,
        continuation: QobuzDownloadContinuation
    ) async throws {
        do {
            for booklet in try await assetWriter.downloadBooklets(
                for: state.outputTuples,
                fileSystem: fileSystem
            ) {
                qobuzLog.info("download.asset", "Booklet downloaded", metadata: ["assetPath": booklet.path])
                continuation.yield(.assetCreated(booklet))
            }
        } catch let error where error.isQobuzCancellation {
            throw NativeQobuzError.cancelled
        } catch {
            qobuzLog.warning("download.asset", "Booklet download failed", error: error)
            continuation.yield(.warning("Booklet: \(error.localizedDescription)"))
        }
    }

    private func writeDescriptions(
        state: QobuzDownloadOperationState,
        fileSystem: LibraryFileSystem,
        continuation: QobuzDownloadContinuation
    ) {
        do {
            for description in try assetWriter.writeAlbumDescriptions(
                for: state.outputTuples,
                fileSystem: fileSystem
            ) {
                qobuzLog.info(
                    "download.asset",
                    "Album description written",
                    metadata: ["assetPath": description.path]
                )
                continuation.yield(.assetCreated(description))
            }
        } catch {
            qobuzLog.warning("download.asset", "Album description could not be written", error: error)
            continuation.yield(.warning("Album description: \(error.localizedDescription)"))
        }
    }

    private func writePlaylist(
        plan: QobuzDownloadPlan,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        continuation: QobuzDownloadContinuation
    ) {
        do {
            if let playlist = try assetWriter.writePlaylist(
                plan: plan,
                outputs: state.outputTuples,
                fileSystem: fileSystem
            ) {
                qobuzLog.info("download.asset", "Playlist file written", metadata: ["assetPath": playlist.path])
                continuation.yield(.assetCreated(playlist))
            }
        } catch {
            qobuzLog.warning("download.asset", "Playlist file could not be written", error: error)
            continuation.yield(.warning("Playlist: \(error.localizedDescription)"))
        }
    }

    private func writeChecksums(
        state: QobuzDownloadOperationState,
        fileSystem: LibraryFileSystem,
        continuation: QobuzDownloadContinuation
    ) {
        do {
            for manifest in try assetWriter.writeChecksumManifests(
                for: state.verifiedOutputTuples,
                fileSystem: fileSystem
            ) {
                qobuzLog.info(
                    "download.asset",
                    "Checksum manifest written",
                    metadata: ["assetPath": manifest.path]
                )
                continuation.yield(.assetCreated(manifest))
            }
        } catch {
            qobuzLog.warning("download.asset", "Checksum manifest could not be written", error: error)
            continuation.yield(.warning("Checksum manifest: \(error.localizedDescription)"))
        }
    }

    private func writePlaylistMetadata(
        plan: QobuzDownloadPlan,
        fileSystem: LibraryFileSystem,
        continuation: QobuzDownloadContinuation
    ) async throws {
        do {
            for asset in try await assetWriter.writePlaylistMetadata(
                plan: plan,
                fileSystem: fileSystem
            ) {
                qobuzLog.info(
                    "download.asset",
                    "Playlist metadata asset written",
                    metadata: ["assetPath": asset.path]
                )
                continuation.yield(.assetCreated(asset))
            }
        } catch let error where error.isQobuzCancellation {
            throw NativeQobuzError.cancelled
        } catch {
            qobuzLog.warning("download.asset", "Playlist metadata could not be written", error: error)
            continuation.yield(.warning("Playlist metadata: \(error.localizedDescription)"))
        }
    }

    private func updateLibrary(
        plan: QobuzDownloadPlan,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        continuation: QobuzDownloadContinuation
    ) {
        do {
            let manifest = try assetWriter.recordLibraryCollections(
                plan: plan,
                outputs: state.outputTuples,
                fileSystem: fileSystem
            )
            try assetWriter.markLibraryManaged(
                state.outputs.map(\.audioURL),
                fileSystem: fileSystem
            )
            qobuzLog.notice(
                "download.library",
                "Library manifest updated",
                metadata: ["manifestPath": manifest.path, "outputCount": String(state.outputs.count)]
            )
            continuation.yield(.assetCreated(manifest))
        } catch {
            qobuzLog.warning("download.library", "Library manifest could not be updated", error: error)
            continuation.yield(.warning("Library manifest: \(error.localizedDescription)"))
        }
    }
}
