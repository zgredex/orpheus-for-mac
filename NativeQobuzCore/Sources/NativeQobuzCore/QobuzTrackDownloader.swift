import Foundation

struct QobuzTrackDownloader: @unchecked Sendable {
    private let service: any QobuzCatalogService
    private let destinationResolver: QobuzDownloadDestinationResolver
    private let existingVerifier: QobuzExistingAudioVerifier
    private let transferPipeline: QobuzTrackTransferPipeline
    private let deliveryPolicy: QobuzDeliveryPolicy
    private let reuseRegistry: QobuzAudioReuseRegistry

    init(
        service: any QobuzCatalogService,
        destinationResolver: QobuzDownloadDestinationResolver,
        existingVerifier: QobuzExistingAudioVerifier,
        transferPipeline: QobuzTrackTransferPipeline,
        deliveryPolicy: QobuzDeliveryPolicy,
        reuseRegistry: QobuzAudioReuseRegistry
    ) {
        self.service = service
        self.destinationResolver = destinationResolver
        self.existingVerifier = existingVerifier
        self.transferPipeline = transferPipeline
        self.deliveryPolicy = deliveryPolicy
        self.reuseRegistry = reuseRegistry
    }

    func process(
        _ item: QobuzResolvedTrack,
        configuration: QobuzDownloadConfiguration,
        fileSystem: LibraryFileSystem,
        state: QobuzDownloadOperationState,
        continuation: QobuzDownloadContinuation
    ) async throws {
        try Task.checkCancellation()
        let trackMetadata = [
            "trackID": item.track.id.rawValue,
            "albumID": item.album.id.rawValue,
            "trackTitle": item.track.displayTitle,
            "position": String(item.position),
            "totalTracks": String(item.total)
        ]
        let trackStarted = Date()
        // Establish track identity before requesting its signed URL. If that
        // request or the subsequent transfer fails, recovery must be budgeted
        // against this track rather than whichever track completed previously.
        continuation.yield(.checkpoint(QobuzDownloadCheckpoint(
            phase: .resolvingAudio,
            trackID: item.track.id,
            albumID: item.album.id
        )))
        qobuzLog.info("download.track", "Resolving downloadable audio file", metadata: trackMetadata)
        let fileInfo = try await QobuzLogScope.withValue(trackMetadata) {
            try await service.fileInfo(trackID: item.track.id, format: configuration.requestedFormat)
        }
        qobuzLog.debug(
            "download.track",
            "Downloadable audio file resolved",
            metadata: trackMetadata.merging([
                "sourceHost": fileInfo.url.host ?? "unknown",
                "formatID": String(fileInfo.formatID)
            ]) { _, new in new }
        )
        try deliveryPolicy.validateCeiling(
            requestedMaximum: configuration.requestedMaximum,
            delivered: fileInfo
        )
        let destination = try destinationResolver.destination(
            for: item,
            fileInfo: fileInfo,
            root: configuration.downloadRoot,
            fileSystem: fileSystem,
            repairTarget: configuration.repairTarget,
            reusableAudio: &state.reusableAudio,
            trackMetadata: trackMetadata
        )
        qobuzLog.debug(
            "download.output",
            "Track output path selected",
            metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new }
        )
        if try await existingVerifier.verifyIfReusable(
            item: item,
            fileInfo: fileInfo,
            requestedMaximum: configuration.requestedMaximum,
            destination: destination,
            repairTarget: configuration.repairTarget,
            root: configuration.downloadRoot,
            fileSystem: fileSystem,
            state: state,
            trackMetadata: trackMetadata,
            trackStarted: trackStarted,
            continuation: continuation
        ) {
            return
        }

        emitDeliveryNotice(
            item: item,
            fileInfo: fileInfo,
            requestedMaximum: configuration.requestedMaximum,
            trackMetadata: trackMetadata,
            continuation: continuation
        )

        let result = try await transferPipeline.transferTrack(
            item: item,
            fileInfo: fileInfo,
            destination: destination,
            repairTarget: configuration.repairTarget,
            fileSystem: fileSystem,
            state: state,
            trackMetadata: trackMetadata,
            continuation: continuation
        )
        state.record(
            QobuzCompletedTrackRecord(
                item: item,
                destination: destination,
                checksum: result.checksum,
                bytes: result.installedBytes,
                delivery: result.delivery
            ),
            disposition: .downloaded,
            reuseRegistry: reuseRegistry,
            root: configuration.downloadRoot
        )
        qobuzLog.notice(
            "download.track",
            "Track download completed",
            metadata: trackMetadata.merging([
                "destinationPath": destination.path,
                "durationMs": String(Int(Date().timeIntervalSince(trackStarted) * 1_000))
            ]) { _, new in new }
        )
        continuation.yield(.trackCompleted(track: item, destination: destination))
        continuation.yield(
            .progress(.completed(completed: item.position, total: item.total, albumBytes: state.albumBytes))
        )
    }

    private func emitDeliveryNotice(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        requestedMaximum: QobuzQuality?,
        trackMetadata: [String: String],
        continuation: QobuzDownloadContinuation
    ) {
        guard let requestedMaximum,
              let notice = deliveryPolicy.notice(
                  for: item,
                  requestedMaximum: requestedMaximum,
                  delivered: fileInfo
              ) else { return }
        let deliveryMetadata: [String: String] = [
            "requestedMaximumFormatID": String(requestedMaximum.maximumFormat.formatID),
            "deliveredFormatID": String(fileInfo.formatID),
            "deliveredBitDepth": fileInfo.bitDepth.map { String($0) } ?? "unknown",
            "deliveredSamplingRate": fileInfo.samplingRate.map { String($0) } ?? "unknown",
            "restrictionCodes": fileInfo.restrictions.map(\.code).joined(separator: ",")
        ]
        qobuzLog.notice(
            "download.quality",
            "Qobuz resolved audio below or with restrictions under the requested maximum",
            metadata: trackMetadata.merging(deliveryMetadata) { _, new in new }
        )
        continuation.yield(.notice(notice))
    }
}
