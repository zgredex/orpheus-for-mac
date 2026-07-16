import Foundation

struct QobuzExistingAudioVerifier: @unchecked Sendable {
    private let validator: any MediaValidating
    private let assetWriter: QobuzCollectionAssetWriter
    private let reuseRegistry: QobuzAudioReuseRegistry
    private let deliveryPolicy: QobuzDeliveryPolicy

    init(
        validator: any MediaValidating,
        assetWriter: QobuzCollectionAssetWriter,
        reuseRegistry: QobuzAudioReuseRegistry,
        deliveryPolicy: QobuzDeliveryPolicy
    ) {
        self.validator = validator
        self.assetWriter = assetWriter
        self.reuseRegistry = reuseRegistry
        self.deliveryPolicy = deliveryPolicy
    }

    func verifyIfReusable(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        destination: URL,
        repairTarget: QobuzArchiveTrack?,
        root: URL,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String],
        trackStarted: Date,
        continuation: QobuzDownloadContinuation
    ) async throws -> Bool {
        let destinationPath = try fileSystem.relativePath(for: destination)
        guard try fileSystem.metadata(at: destinationPath)?.kind == .regularFile,
              let provenance = try? assetWriter.provenance(for: destination, fileSystem: fileSystem),
              provenance.matchesIdentityAndFormat(item: item, fileInfo: fileInfo) else { return false }
        do {
            continuation.yield(.validating(track: item))
            let media = try await validator.validate(destination, fileSystem: fileSystem)
            let delivery = try deliveryPolicy.validate(fileInfo: fileInfo, media: media)
            guard provenance.matches(item: item, delivery: delivery) else {
                throw NativeQobuzError.invalidResponse(
                    "Existing file properties do not match its archive provenance"
                )
            }
            try Task.checkCancellation()
            let checksum = try MusicFileIntegrity.sha256(of: destinationPath, in: fileSystem)
            guard provenance.sha256.caseInsensitiveCompare(checksum) == .orderedSame else {
                throw NativeQobuzError.invalidResponse("Existing file checksum does not match")
            }
            try assetWriter.recordProvenance(
                QobuzFileProvenance(
                    item: item,
                    delivery: delivery,
                    sha256: checksum,
                    archiveKind: repairTarget?.archiveKind
                        ?? (provenance.archiveKind == .unclassified ? nil : provenance.archiveKind)
                ),
                for: destination,
                fileSystem: fileSystem
            )
            let size = try fileSystem.metadata(at: destinationPath)?.byteCount ?? 0
            state.recordSkipped(
                item: item,
                destination: destination,
                checksum: checksum,
                bytes: size,
                delivery: delivery,
                reuseRegistry: reuseRegistry,
                root: root
            )
            continuation.yield(.integrityVerified(track: item, sha256: checksum))
            continuation.yield(.trackSkipped(track: item, destination: destination))
            qobuzLog.notice(
                "download.reuse",
                "Existing audio passed validation and checksum verification",
                metadata: trackMetadata.merging([
                    "destinationPath": destination.path,
                    "sha256": checksum,
                    "durationMs": String(Int(Date().timeIntervalSince(trackStarted) * 1_000))
                ]) { _, new in new }
            )
            continuation.yield(
                .progress(
                    .completed(
                        completed: item.position,
                        total: item.total,
                        albumBytes: state.albumBytes
                    )
                )
            )
            return true
        } catch let error where error.isQobuzCancellation {
            throw NativeQobuzError.cancelled
        } catch {
            qobuzLog.warning(
                "download.reuse",
                "Existing audio failed verification and will be downloaded again",
                metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new },
                error: error
            )
            return false
        }
    }
}
