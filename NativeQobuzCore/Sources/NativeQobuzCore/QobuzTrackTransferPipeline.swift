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
    private let fileManager: FileManager

    init(
        transfer: any FileTransferClient,
        validator: any MediaValidating,
        metadataWriter: any AudioMetadataWriting,
        assetWriter: QobuzCollectionAssetWriter,
        deliveryPolicy: QobuzDeliveryPolicy,
        fileManager: FileManager
    ) {
        self.transfer = transfer
        self.validator = validator
        self.metadataWriter = metadataWriter
        self.assetWriter = assetWriter
        self.deliveryPolicy = deliveryPolicy
        self.fileManager = fileManager
    }

    func transferTrack(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        destination: URL,
        repairTarget: QobuzArchiveTrack?,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) async throws -> QobuzTrackTransferResult {
        continuation.yield(.trackStarted(track: item, destination: destination, format: fileInfo.format))
        let artworkTask = artworkTask(for: item, state: state, trackMetadata: trackMetadata)
        let staging = QobuzDownloadArtifacts.processingURL(for: destination, formatID: fileInfo.formatID)
        defer { removeStagingFileIfPresent(staging, trackMetadata: trackMetadata) }

        do {
            qobuzLog.info(
                "download.transfer",
                "Track audio transfer started",
                metadata: trackMetadata.merging([
                    "stagingPath": staging.path,
                    "partialPath": QobuzDownloadArtifacts.partialURL(
                        for: destination,
                        formatID: fileInfo.formatID
                    ).path
                ]) { _, new in new }
            )
            let transferEvents = await QobuzLogScope.withValue(trackMetadata) {
                transfer.events(from: fileInfo.url, to: staging)
            }
            for try await transferEvent in transferEvents {
                try Task.checkCancellation()
                guard case .progress(let progress) = transferEvent else { continue }
                let fileFraction = progress.fraction
                let overall = (Double(item.position - 1) + (fileFraction ?? 0)) / Double(max(item.total, 1))
                state.currentTrackBytes = progress.bytesWritten
                continuation.yield(
                    .progress(
                        QobuzDownloadProgress(
                            completedTracks: item.position - 1,
                            totalTracks: item.total,
                            currentTrackFraction: fileFraction,
                            overallFraction: overall,
                            bytesWritten: progress.bytesWritten,
                            totalBytes: progress.totalBytes,
                            bytesPerSecond: progress.bytesPerSecond,
                            albumBytesWritten: state.albumBytes + state.currentTrackBytes
                        )
                    )
                )
            }
            qobuzLog.info("download.transfer", "Track audio transfer finished", metadata: trackMetadata)

            let artwork = try await resolvedArtwork(
                from: artworkTask,
                item: item,
                state: state,
                trackMetadata: trackMetadata,
                continuation: continuation
            )
            continuation.yield(.tagging(track: item))
            qobuzLog.info("download.metadata", "Writing audio metadata and artwork", metadata: trackMetadata)
            try metadataWriter.write(metadata: QobuzAudioMetadata(item: item), artwork: artwork, to: staging)
            qobuzLog.debug("download.metadata", "Audio metadata written", metadata: trackMetadata)
            continuation.yield(.validating(track: item))
            let media = try await validator.validate(staging)
            let delivery = try deliveryPolicy.validate(fileInfo: fileInfo, media: media)
            try Task.checkCancellation()
            let checksum = try MusicFileIntegrity.sha256(of: staging)
            qobuzLog.info(
                "download.integrity",
                "Track checksum calculated",
                metadata: trackMetadata.merging(["sha256": checksum]) { _, new in new }
            )
            try install(staging, at: destination)
            qobuzLog.info(
                "download.output",
                "Validated audio installed at final destination",
                metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new }
            )
            try assetWriter.recordProvenance(
                QobuzFileProvenance(
                    item: item,
                    delivery: delivery,
                    sha256: checksum,
                    archiveKind: repairTarget?.archiveKind
                ),
                for: destination
            )
            continuation.yield(.integrityVerified(track: item, sha256: checksum))
            if let artwork {
                saveExternalArtwork(
                    artwork,
                    item: item,
                    destination: destination,
                    trackMetadata: trackMetadata,
                    continuation: continuation
                )
            }
            let size = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            return QobuzTrackTransferResult(
                checksum: checksum,
                installedBytes: size?.int64Value ?? state.currentTrackBytes,
                delivery: delivery
            )
        } catch {
            artworkTask.cancel()
            throw error
        }
    }

    private func artworkTask(
        for item: QobuzResolvedTrack,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String]
    ) -> Task<EmbeddedArtwork?, Error> {
        if let cached = state.artworkCache[item.album.id] {
            return Task { cached }
        }
        if state.albumsWithoutArtwork.contains(item.album.id) {
            return Task { nil }
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
            state.albumsWithoutArtwork.insert(item.album.id)
            qobuzLog.warning(
                "download.artwork",
                "Album artwork could not be downloaded",
                metadata: trackMetadata,
                error: error
            )
            continuation.yield(.warning("Artwork: \(error.localizedDescription)"))
            return nil
        }
        if let artwork {
            state.artworkCache[item.album.id] = artwork
        } else {
            state.albumsWithoutArtwork.insert(item.album.id)
        }
        return artwork
    }

    private func saveExternalArtwork(
        _ artwork: EmbeddedArtwork,
        item: QobuzResolvedTrack,
        destination: URL,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) {
        do {
            if let cover = try assetWriter.saveExternalArtwork(artwork, for: item, audioURL: destination) {
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

    private func removeStagingFileIfPresent(_ staging: URL, trackMetadata: [String: String]) {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        do {
            try fileManager.removeItem(at: staging)
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

    private func install(_ staging: URL, at destination: URL) throws {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw NativeQobuzError.fileSystem(error.localizedDescription)
        }
    }
}
