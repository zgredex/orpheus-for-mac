import Foundation

/// Public composition root for the download domain. Runtime work is owned by
/// the operation, track, transfer, reuse, destination, and finalization components.
public final class NativeQobuzDownloadEngine: @unchecked Sendable {
    private let operation: QobuzDownloadOperation

    public init(
        service: any QobuzCatalogService,
        transfer: any FileTransferClient = URLSessionFileTransferClient(),
        outputPlanner: any QobuzOutputPlanning = StandardQobuzOutputPlanner(),
        validator: any MediaValidating,
        metadataWriter: any AudioMetadataWriting = NativeAudioMetadataWriter(),
        assetWriter: QobuzCollectionAssetWriter? = nil,
        reusableAudioIndex: QobuzReusableAudioIndex = QobuzReusableAudioIndex()
    ) {
        let assetWriter = assetWriter ?? QobuzCollectionAssetWriter(outputPlanner: outputPlanner)
        let reuseRegistry = QobuzAudioReuseRegistry(assetWriter: assetWriter, index: reusableAudioIndex)
        let deliveryPolicy = QobuzDeliveryPolicy()
        let destinationResolver = QobuzDownloadDestinationResolver(
            outputPlanner: outputPlanner,
            assetWriter: assetWriter,
            reuseRegistry: reuseRegistry
        )
        let existingVerifier = QobuzExistingAudioVerifier(
            validator: validator,
            assetWriter: assetWriter,
            reuseRegistry: reuseRegistry,
            deliveryPolicy: deliveryPolicy
        )
        let transferPipeline = QobuzTrackTransferPipeline(
            transfer: transfer,
            validator: validator,
            metadataWriter: metadataWriter,
            assetWriter: assetWriter,
            deliveryPolicy: deliveryPolicy
        )
        let trackDownloader = QobuzTrackDownloader(
            service: service,
            destinationResolver: destinationResolver,
            existingVerifier: existingVerifier,
            transferPipeline: transferPipeline,
            deliveryPolicy: deliveryPolicy,
            reuseRegistry: reuseRegistry
        )
        operation = QobuzDownloadOperation(
            resolver: QobuzCatalogResolver(service: service),
            destinationResolver: destinationResolver,
            reuseRegistry: reuseRegistry,
            trackDownloader: trackDownloader,
            finalizer: QobuzDownloadFinalizer(assetWriter: assetWriter)
        )
    }

    public func events(
        for request: QobuzRequest,
        quality: QobuzQuality,
        downloadRoot: URL,
        includedTrackIDs: Set<QobuzID>? = nil
    ) -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        operation.events(
            for: QobuzDownloadConfiguration(
                request: request,
                requestedFormat: quality.maximumFormat,
                requestedMaximum: quality,
                downloadRoot: downloadRoot,
                repairTarget: nil,
                includedTrackIDs: includedTrackIDs
            )
        )
    }

    public func repairEvents(
        for target: QobuzArchiveTrack,
        downloadRoot: URL
    ) throws -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        guard let format = target.audioFormat else {
            throw NativeQobuzError.unavailable(
                "The archived Qobuz format \(target.formatID) is not supported for automatic repair."
            )
        }
        return operation.events(
            for: QobuzDownloadConfiguration(
                request: .track(QobuzID(target.qobuzTrackID)),
                requestedFormat: format,
                requestedMaximum: nil,
                downloadRoot: downloadRoot,
                repairTarget: target,
                includedTrackIDs: nil
            )
        )
    }
}
