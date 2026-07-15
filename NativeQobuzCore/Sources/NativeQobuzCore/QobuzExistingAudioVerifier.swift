import Foundation

struct QobuzExistingAudioVerifier: @unchecked Sendable {
    private let validator: any MediaValidating
    private let assetWriter: QobuzCollectionAssetWriter
    private let reuseRegistry: QobuzAudioReuseRegistry
    private let deliveryPolicy: QobuzDeliveryPolicy
    private let fileManager: FileManager

    init(
        validator: any MediaValidating,
        assetWriter: QobuzCollectionAssetWriter,
        reuseRegistry: QobuzAudioReuseRegistry,
        deliveryPolicy: QobuzDeliveryPolicy,
        fileManager: FileManager
    ) {
        self.validator = validator
        self.assetWriter = assetWriter
        self.reuseRegistry = reuseRegistry
        self.deliveryPolicy = deliveryPolicy
        self.fileManager = fileManager
    }

    func verifyIfReusable(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        destination: URL,
        repairTarget: QobuzArchiveTrack?,
        root: URL,
        state: QobuzDownloadOperationState,
        trackMetadata: [String: String],
        trackStarted: Date,
        continuation: QobuzDownloadContinuation
    ) async throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path),
              let provenance = try? assetWriter.provenance(for: destination),
              provenance.matchesIdentityAndFormat(item: item, fileInfo: fileInfo) else { return false }
        do {
            continuation.yield(.validating(track: item))
            let media = try await validator.validate(destination)
            let delivery = try deliveryPolicy.validate(fileInfo: fileInfo, media: media)
            guard provenance.matches(item: item, delivery: delivery) else {
                throw NativeQobuzError.invalidResponse(
                    "Existing file properties do not match its archive provenance"
                )
            }
            try Task.checkCancellation()
            let checksum = try MusicFileIntegrity.sha256(of: destination)
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
                for: destination
            )
            let size = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            state.recordSkipped(
                item: item,
                destination: destination,
                checksum: checksum,
                bytes: size?.int64Value ?? 0,
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
