import Foundation

struct QobuzTrackTransferResult: Sendable {
    let checksum: String
    let installedBytes: Int64
    let delivery: QobuzValidatedAudioDelivery
}

struct QobuzTrackTransferPipeline: @unchecked Sendable {
    private let transfer: any FileTransferClient
    private let validator: any MediaValidating
    private let metadataWriter: any AudioMetadataWriting
    private let assetWriter: QobuzCollectionAssetWriter
    private let deliveryPolicy: QobuzDeliveryPolicy
    private let commitTransaction: QobuzTrackCommitTransaction

    init(
        transfer: any FileTransferClient,
        validator: any MediaValidating,
        metadataWriter: any AudioMetadataWriting,
        assetWriter: QobuzCollectionAssetWriter,
        deliveryPolicy: QobuzDeliveryPolicy,
        commitTransaction: QobuzTrackCommitTransaction = QobuzTrackCommitTransaction()
    ) {
        self.transfer = transfer
        self.validator = validator
        self.metadataWriter = metadataWriter
        self.assetWriter = assetWriter
        self.deliveryPolicy = deliveryPolicy
        self.commitTransaction = commitTransaction
    }

    func transferTrack(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        destination: URL,
        repairTarget: QobuzArchiveTrack?,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) async throws -> QobuzTrackTransferResult {
        continuation.yield(.trackStarted(track: item, destination: destination, format: fileInfo.format))
        let artworkTask = artworkTask(for: item, state: state, trackMetadata: trackMetadata)
        let staging = QobuzDownloadArtifacts.processingURL(
            for: destination,
            formatID: fileInfo.formatID,
            albumID: item.album.id,
            trackID: item.track.id
        )

        do {
            continuation.yield(.checkpoint(QobuzDownloadCheckpoint(
                phase: .transferringAudio,
                trackID: item.track.id,
                albumID: item.album.id,
                outputURL: staging
            )))
            try await transferUnlessStaged(
                item: item,
                fileInfo: fileInfo,
                destination: destination,
                staging: staging,
                fileSystem: fileSystem,
                state: state,
                trackMetadata: trackMetadata,
                continuation: continuation
            )

            let artwork = try await resolvedArtwork(
                from: artworkTask,
                item: item,
                state: state,
                trackMetadata: trackMetadata,
                continuation: continuation
            )
            continuation.yield(.checkpoint(QobuzDownloadCheckpoint(
                phase: .writingTags,
                trackID: item.track.id,
                albumID: item.album.id,
                outputURL: staging
            )))
            continuation.yield(.tagging(track: item))
            qobuzLog.info("download.metadata", "Writing audio metadata and artwork", metadata: trackMetadata)
            let checksum = try metadataWriter.write(
                metadata: QobuzAudioMetadata(item: item),
                artwork: artwork,
                to: staging,
                fileSystem: fileSystem
            )
            qobuzLog.debug("download.metadata", "Audio metadata written", metadata: trackMetadata)
            continuation.yield(.checkpoint(QobuzDownloadCheckpoint(
                phase: .validatingAudio,
                trackID: item.track.id,
                albumID: item.album.id,
                outputURL: staging
            )))
            continuation.yield(.validating(track: item))
            let delivery: QobuzValidatedAudioDelivery
            do {
                let media = try await validator.validate(staging, fileSystem: fileSystem)
                delivery = try deliveryPolicy.validate(fileInfo: fileInfo, media: media)
            } catch let error where error.isQobuzCancellation {
                throw NativeQobuzError.cancelled
            } catch {
                removeStagingFileIfPresent(staging, fileSystem: fileSystem, trackMetadata: trackMetadata)
                throw error
            }
            try Task.checkCancellation()
            qobuzLog.info(
                "download.integrity",
                "Track checksum finalized during metadata write",
                metadata: trackMetadata.merging(["sha256": checksum]) { _, new in new }
            )
            continuation.yield(.checkpoint(QobuzDownloadCheckpoint(
                phase: .writingProvenance,
                trackID: item.track.id,
                albumID: item.album.id,
                outputURL: destination
            )))
            let provenance = QobuzFileProvenance(
                item: item,
                delivery: delivery,
                sha256: checksum,
                archiveKind: repairTarget?.archiveKind,
                isLibraryManaged: repairTarget?.isLibraryManaged ?? false
            )
            try await commitTransaction.commit(
                provenance: provenance,
                expectedSHA256: checksum,
                stagingURL: staging,
                destinationURL: destination,
                fileSystem: fileSystem
            )
            qobuzLog.info(
                "download.output",
                "Validated audio and provenance committed at final destination",
                metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new }
            )
            continuation.yield(.integrityVerified(track: item, sha256: checksum))
            if let artwork {
                saveExternalArtwork(
                    artwork,
                    item: item,
                    destination: destination,
                    fileSystem: fileSystem,
                    trackMetadata: trackMetadata,
                    continuation: continuation
                )
            }
            let size = try fileSystem.metadata(at: fileSystem.relativePath(for: destination))?.byteCount
            return QobuzTrackTransferResult(
                checksum: checksum,
                installedBytes: size ?? state.currentTrackBytes,
                delivery: delivery
            )
        } catch {
            artworkTask.cancel()
            throw error
        }
    }

    private func transferUnlessStaged(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        destination: URL,
        staging: URL,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) async throws {
        let stagingPath = try fileSystem.relativePath(for: staging)
        if let metadata = try fileSystem.metadata(at: stagingPath) {
            guard metadata.kind == .regularFile else {
                throw NativeQobuzError.fileSystem("The recovered audio staging item is not a regular file.")
            }
            state.currentTrackBytes = metadata.byteCount
            qobuzLog.notice(
                "download.recovery.finalization",
                "Completed audio staging file recovered; network transfer skipped",
                metadata: trackMetadata.merging([
                    "stagingPath": staging.path,
                    "stagingBytes": String(metadata.byteCount)
                ]) { _, new in new }
            )
            continuation.yield(.notice("Resuming metadata and validation from completed audio"))
            return
        }

        qobuzLog.info(
            "download.transfer",
            "Track audio transfer started",
            metadata: trackMetadata.merging([
                "stagingPath": staging.path,
                "partialPath": QobuzDownloadArtifacts.partialURL(
                    for: destination,
                    formatID: fileInfo.formatID,
                    albumID: item.album.id,
                    trackID: item.track.id
                ).path
            ]) { _, new in new }
        )
        let transferEvents = await QobuzLogScope.withValue(trackMetadata) {
            transfer.events(from: fileInfo.url, to: staging, fileSystem: fileSystem)
        }
        var progressLimiter = QobuzDownloadProgressLimiter()
        for try await transferEvent in transferEvents {
            try Task.checkCancellation()
            guard case .progress(let progress) = transferEvent else { continue }
            let fileFraction = progress.fraction
            let overall = (Double(item.position - 1) + (fileFraction ?? 0)) / Double(max(item.total, 1))
            state.currentTrackBytes = progress.bytesWritten
            guard progressLimiter.shouldEmit(fraction: fileFraction) else { continue }
            continuation.yield(.progress(QobuzDownloadProgress(
                completedTracks: item.position - 1,
                totalTracks: item.total,
                currentTrackFraction: fileFraction,
                overallFraction: overall,
                bytesWritten: progress.bytesWritten,
                totalBytes: progress.totalBytes,
                bytesPerSecond: progress.bytesPerSecond,
                albumBytesWritten: state.albumBytes + state.currentTrackBytes
            )))
        }
        qobuzLog.info("download.transfer", "Track audio transfer finished", metadata: trackMetadata)
    }

    private func artworkTask(
        for item: QobuzResolvedTrack,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String]
    ) -> Task<EmbeddedArtwork?, Error> {
        switch state.artworkCache.lookup(item.album.id) {
        case .artwork(let cached):
            return Task { cached }
        case .missing:
            return Task { nil }
        case .notCached:
            break
        }
        return Task {
            try await QobuzLogScope.withValue(trackMetadata) {
                try await assetWriter.artwork(for: item.album)
            }
        }
    }

    private func resolvedArtwork(
        from task: Task<EmbeddedArtwork?, Error>,
        item: QobuzResolvedTrack,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) async throws -> EmbeddedArtwork? {
        let artwork: EmbeddedArtwork?
        do {
            artwork = try await task.value
        } catch let error where error.isQobuzCancellation {
            throw NativeQobuzError.cancelled
        } catch {
            state.artworkCache.store(nil, for: item.album.id)
            qobuzLog.warning(
                "download.artwork",
                "Album artwork could not be downloaded",
                metadata: trackMetadata,
                error: error
            )
            continuation.yield(.warning("Artwork: \(error.localizedDescription)"))
            return nil
        }
        state.artworkCache.store(artwork, for: item.album.id)
        return artwork
    }

    private func saveExternalArtwork(
        _ artwork: EmbeddedArtwork,
        item: QobuzResolvedTrack,
        destination: URL,
        fileSystem: LibraryFileSystem,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) {
        do {
            if let cover = try assetWriter.saveExternalArtwork(
                artwork,
                for: item,
                audioURL: destination,
                fileSystem: fileSystem
            ) {
                continuation.yield(.assetCreated(cover))
            }
        } catch {
            qobuzLog.warning(
                "download.asset",
                "External cover could not be saved",
                metadata: trackMetadata,
                error: error
            )
            continuation.yield(.warning("Cover: \(error.localizedDescription)"))
        }
    }

    private func removeStagingFileIfPresent(
        _ staging: URL,
        fileSystem: LibraryFileSystem,
        trackMetadata: [String: String]
    ) {
        do {
            let path = try fileSystem.relativePath(for: staging)
            guard try fileSystem.metadata(at: path) != nil else { return }
            try fileSystem.removeFile(path)
            qobuzLog.trace(
                "download.cleanup",
                "Removed track staging file",
                metadata: trackMetadata.merging(["stagingPath": staging.path]) { _, new in new }
            )
        } catch {
            qobuzLog.warning(
                "download.cleanup",
                "Could not remove track staging file",
                metadata: trackMetadata.merging(["stagingPath": staging.path]) { _, new in new },
                error: error
            )
        }
    }

}
