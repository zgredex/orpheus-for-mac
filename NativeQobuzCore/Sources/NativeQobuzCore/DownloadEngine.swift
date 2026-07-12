import Foundation

public struct QobuzDownloadProgress: Equatable, Sendable {
    public let completedTracks: Int
    public let totalTracks: Int
    public let currentTrackFraction: Double?
    public let overallFraction: Double
    public let bytesWritten: Int64?
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?

    public init(
        completedTracks: Int,
        totalTracks: Int,
        currentTrackFraction: Double?,
        overallFraction: Double,
        bytesWritten: Int64?,
        totalBytes: Int64?,
        bytesPerSecond: Double?
    ) {
        self.completedTracks = completedTracks
        self.totalTracks = totalTracks
        self.currentTrackFraction = currentTrackFraction
        self.overallFraction = min(max(overallFraction.isFinite ? overallFraction : 0, 0), 1)
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum QobuzDownloadEvent: Equatable, Sendable {
    case resolving(QobuzRequest)
    case planReady(title: String, trackCount: Int)
    case trackStarted(track: QobuzResolvedTrack, destination: URL)
    case progress(QobuzDownloadProgress)
    case trackCompleted(track: QobuzResolvedTrack, destination: URL)
    case trackSkipped(track: QobuzResolvedTrack, destination: URL)
    case completed(title: String, downloaded: Int, skipped: Int)
}

public final class NativeQobuzDownloadEngine: @unchecked Sendable {
    private let service: any QobuzCatalogService
    private let resolver: QobuzCatalogResolver
    private let transfer: any FileTransferClient
    private let outputPlanner: any QobuzOutputPlanning
    private let fileManager: FileManager

    public init(
        service: any QobuzCatalogService,
        transfer: any FileTransferClient = URLSessionFileTransferClient(),
        outputPlanner: any QobuzOutputPlanning = StandardQobuzOutputPlanner(),
        fileManager: FileManager = .default
    ) {
        self.service = service
        self.resolver = QobuzCatalogResolver(service: service)
        self.transfer = transfer
        self.outputPlanner = outputPlanner
        self.fileManager = fileManager
    }

    public func events(
        for request: QobuzRequest,
        quality: QobuzQuality,
        downloadRoot: URL
    ) -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.resolving(request))
                    let plan = try await resolver.resolve(request)
                    try Task.checkCancellation()
                    continuation.yield(.planReady(title: plan.title, trackCount: plan.tracks.count))

                    var downloaded = 0
                    var skipped = 0
                    for item in plan.tracks {
                        try Task.checkCancellation()
                        let fileInfo = try await service.fileInfo(trackID: item.track.id, quality: quality)
                        let destination = outputPlanner.destination(for: item, fileInfo: fileInfo, root: downloadRoot)

                        if fileManager.fileExists(atPath: destination.path) {
                            skipped += 1
                            continuation.yield(.trackSkipped(track: item, destination: destination))
                            continuation.yield(
                                .progress(
                                    completedProgress(
                                        completed: item.position,
                                        total: item.total
                                    )
                                )
                            )
                            continue
                        }

                        continuation.yield(.trackStarted(track: item, destination: destination))
                        for try await transferEvent in transfer.events(from: fileInfo.url, to: destination) {
                            try Task.checkCancellation()
                            switch transferEvent {
                            case .started, .completed:
                                break
                            case .progress(let progress):
                                let fileFraction = progress.fraction
                                let overall = (
                                    Double(item.position - 1) + (fileFraction ?? 0)
                                ) / Double(max(item.total, 1))
                                continuation.yield(
                                    .progress(
                                        QobuzDownloadProgress(
                                            completedTracks: item.position - 1,
                                            totalTracks: item.total,
                                            currentTrackFraction: fileFraction,
                                            overallFraction: overall,
                                            bytesWritten: progress.bytesWritten,
                                            totalBytes: progress.totalBytes,
                                            bytesPerSecond: progress.bytesPerSecond
                                        )
                                    )
                                )
                            }
                        }
                        downloaded += 1
                        continuation.yield(.trackCompleted(track: item, destination: destination))
                        continuation.yield(.progress(completedProgress(completed: item.position, total: item.total)))
                    }
                    continuation.yield(.completed(title: plan.title, downloaded: downloaded, skipped: skipped))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: NativeQobuzError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func completedProgress(completed: Int, total: Int) -> QobuzDownloadProgress {
        QobuzDownloadProgress(
            completedTracks: completed,
            totalTracks: total,
            currentTrackFraction: 1,
            overallFraction: Double(completed) / Double(max(total, 1)),
            bytesWritten: nil,
            totalBytes: nil,
            bytesPerSecond: nil
        )
    }
}
