import Foundation

final class QobuzDownloadOperation: @unchecked Sendable {
    private let resolver: QobuzCatalogResolver
    private let destinationResolver: QobuzDownloadDestinationResolver
    private let reuseRegistry: QobuzAudioReuseRegistry
    private let trackDownloader: QobuzTrackDownloader
    private let finalizer: QobuzDownloadFinalizer

    init(
        resolver: QobuzCatalogResolver,
        destinationResolver: QobuzDownloadDestinationResolver,
        reuseRegistry: QobuzAudioReuseRegistry,
        trackDownloader: QobuzTrackDownloader,
        finalizer: QobuzDownloadFinalizer
    ) {
        self.resolver = resolver
        self.destinationResolver = destinationResolver
        self.reuseRegistry = reuseRegistry
        self.trackDownloader = trackDownloader
        self.finalizer = finalizer
    }

    func events(for configuration: QobuzDownloadConfiguration) -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        let operationMetadata = configuration.logMetadata
        return AsyncThrowingStream { continuation in
            let task = Task {
                await QobuzLogScope.withValue(operationMetadata) {
                    await self.run(configuration, continuation: continuation)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func run(
        _ configuration: QobuzDownloadConfiguration,
        continuation: QobuzDownloadContinuation
    ) async {
        let operationStarted = Date()
        qobuzLog.notice("download.lifecycle", "Download operation started")
        do {
            let fileSystem = try LibraryFileSystem(rootURL: configuration.downloadRoot)
            try LibraryFileTransaction.recoverInterruptedTransactions(in: fileSystem)
            continuation.yield(.checkpoint(QobuzDownloadCheckpoint(phase: .resolvingCatalog)))
            continuation.yield(.resolving(configuration.request))
            let plan = try await resolver.resolve(configuration.request)
                .selecting(trackIDs: configuration.includedTrackIDs)
            try Task.checkCancellation()
            try destinationResolver.validate(plan: plan, repairTarget: configuration.repairTarget)
            qobuzLog.info(
                "download.plan",
                "Download plan accepted",
                metadata: ["title": plan.title, "trackCount": String(plan.tracks.count)]
            )
            continuation.yield(.planReady(title: plan.title, trackCount: plan.tracks.count))

            let state = QobuzDownloadOperationState(
                reusableAudio: reuseRegistry.load(fileSystem: fileSystem)
            )
            for item in plan.tracks {
                try await trackDownloader.process(
                    item,
                    configuration: configuration,
                    fileSystem: fileSystem,
                    state: state,
                    continuation: continuation
                )
            }
            try await finalizer.finalize(
                plan: plan,
                configuration: configuration,
                fileSystem: fileSystem,
                state: state,
                continuation: continuation
            )
            qobuzLog.notice(
                "download.lifecycle",
                "Download operation completed",
                metadata: [
                    "title": plan.title,
                    "downloaded": String(state.downloaded),
                    "skipped": String(state.skipped),
                    "outputCount": String(state.outputs.count),
                    "durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))
                ]
            )
            continuation.yield(.completed(title: plan.title, downloaded: state.downloaded, skipped: state.skipped))
            continuation.finish()
        } catch let error where error.isQobuzCancellation {
            qobuzLog.notice(
                "download.lifecycle",
                "Download operation cancelled",
                metadata: ["durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))]
            )
            continuation.finish(throwing: NativeQobuzError.cancelled)
        } catch {
            qobuzLog.error(
                "download.lifecycle",
                "Download operation failed",
                metadata: ["durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))],
                error: error
            )
            continuation.finish(throwing: error)
        }
    }
}
