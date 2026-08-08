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
        let interval = QobuzPerformanceSignposts.begin(
            "DownloadFinalization",
            metadata: "tracks=\(state.outputs.count) repair=\(configuration.repairTarget != nil)"
        )
        defer {
            QobuzPerformanceSignposts.end(
                interval,
                metadata: "tracks=\(state.outputs.count)"
            )
        }
        continuation.yield(.checkpoint(QobuzDownloadCheckpoint(phase: .writingCollectionAssets)))
        try await writeBooklets(state: state, fileSystem: fileSystem, continuation: continuation)
        try Task.checkCancellation()
        writeDescriptions(state: state, fileSystem: fileSystem, continuation: continuation)
        try Task.checkCancellation()
        writeChecksums(state: state, fileSystem: fileSystem, continuation: continuation)
        try Task.checkCancellation()
        try await writePlaylistMetadata(plan: plan, fileSystem: fileSystem, continuation: continuation)
        guard configuration.repairTarget == nil else {
            continuation.yield(.checkpoint(QobuzDownloadCheckpoint(phase: .indexingLibrary)))
            return
        }
        try Task.checkCancellation()
        try await updateLibrary(plan: plan, fileSystem: fileSystem, state: state, continuation: continuation)
        // This checkpoint is a durable receipt: every Qobuz/core finalization
        // step, including the Library manifest transaction, has committed.
        // The app may now resume its archive projection without resolving the
        // catalog or downloading audio again.
        continuation.yield(.checkpoint(QobuzDownloadCheckpoint(phase: .indexingLibrary)))
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
    ) async throws {
        let assets = try await assetWriter.updateLibraryCollections(
            plan: plan,
            outputs: state.outputTuples,
            fileSystem: fileSystem
        )
        qobuzLog.notice(
            "download.library",
            "Library manifest transaction committed",
            metadata: [
                "manifestPath": assets.manifestURL.path,
                "playlistPath": assets.playlistURL?.path ?? "none",
                "outputCount": String(state.outputs.count)
            ]
        )
        if let playlistURL = assets.playlistURL {
            continuation.yield(.assetCreated(playlistURL))
        }
        continuation.yield(.assetCreated(assets.manifestURL))
    }
}
