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
    case validating(track: QobuzResolvedTrack)
    case tagging(track: QobuzResolvedTrack)
    case integrityVerified(track: QobuzResolvedTrack, sha256: String)
    case assetCreated(URL)
    case trackCompleted(track: QobuzResolvedTrack, destination: URL)
    case trackSkipped(track: QobuzResolvedTrack, destination: URL)
    case completed(title: String, downloaded: Int, skipped: Int)
}

public final class NativeQobuzDownloadEngine: @unchecked Sendable {
    private let service: any QobuzCatalogService
    private let resolver: QobuzCatalogResolver
    private let transfer: any FileTransferClient
    private let outputPlanner: any QobuzOutputPlanning
    private let validator: any MediaValidating
    private let metadataWriter: any AudioMetadataWriting
    private let assetWriter: QobuzCollectionAssetWriter
    private let fileManager: FileManager

    public init(
        service: any QobuzCatalogService,
        transfer: any FileTransferClient = URLSessionFileTransferClient(),
        outputPlanner: any QobuzOutputPlanning = StandardQobuzOutputPlanner(),
        validator: any MediaValidating,
        metadataWriter: any AudioMetadataWriting = NativeAudioMetadataWriter(),
        assetWriter: QobuzCollectionAssetWriter = QobuzCollectionAssetWriter(),
        fileManager: FileManager = .default
    ) {
        self.service = service
        self.resolver = QobuzCatalogResolver(service: service)
        self.transfer = transfer
        self.outputPlanner = outputPlanner
        self.validator = validator
        self.metadataWriter = metadataWriter
        self.assetWriter = assetWriter
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
                    var outputs: [(item: QobuzResolvedTrack, audioURL: URL)] = []
                    var verifiedOutputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)] = []
                    var artworkCache: [QobuzID: EmbeddedArtwork] = [:]
                    var albumsWithoutArtwork = Set<QobuzID>()
                    for item in plan.tracks {
                        try Task.checkCancellation()
                        let fileInfo = try await service.fileInfo(trackID: item.track.id, quality: quality)
                        let destination = outputPlanner.destination(for: item, fileInfo: fileInfo, root: downloadRoot)

                        if fileManager.fileExists(atPath: destination.path) {
                            do {
                                continuation.yield(.validating(track: item))
                                try await validator.validate(destination)
                                try Task.checkCancellation()
                                let checksum = try MusicFileIntegrity.sha256(of: destination)
                                if let expected = try assetWriter.expectedChecksum(for: destination),
                                   expected.caseInsensitiveCompare(checksum) != .orderedSame {
                                    throw NativeQobuzError.invalidResponse("Existing file checksum does not match")
                                }
                                skipped += 1
                                outputs.append((item, destination))
                                verifiedOutputs.append((item, destination, checksum))
                                continuation.yield(.integrityVerified(track: item, sha256: checksum))
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
                            } catch is CancellationError {
                                throw NativeQobuzError.cancelled
                            } catch NativeQobuzError.cancelled {
                                throw NativeQobuzError.cancelled
                            } catch {
                                try? fileManager.removeItem(at: destination)
                            }
                        }

                        continuation.yield(.trackStarted(track: item, destination: destination))
                        let artworkTask: Task<EmbeddedArtwork?, Error>
                        if let cached = artworkCache[item.album.id] {
                            artworkTask = Task { cached }
                        } else if albumsWithoutArtwork.contains(item.album.id) {
                            artworkTask = Task { nil }
                        } else {
                            artworkTask = Task { try await assetWriter.artwork(for: item.album) }
                        }
                        let staging = processingURL(for: destination)
                        defer { try? fileManager.removeItem(at: staging) }
                        do {
                            for try await transferEvent in transfer.events(from: fileInfo.url, to: staging) {
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
                            let artwork = try await artworkTask.value
                            if let artwork {
                                artworkCache[item.album.id] = artwork
                            } else {
                                albumsWithoutArtwork.insert(item.album.id)
                            }
                            continuation.yield(.tagging(track: item))
                            try metadataWriter.write(metadata: QobuzAudioMetadata(item: item), artwork: artwork, to: staging)
                            continuation.yield(.validating(track: item))
                            try await validator.validate(staging)
                            try Task.checkCancellation()
                            let checksum = try MusicFileIntegrity.sha256(of: staging)
                            try install(staging, at: destination)
                            verifiedOutputs.append((item, destination, checksum))
                            continuation.yield(.integrityVerified(track: item, sha256: checksum))
                            if let artwork,
                               let cover = try assetWriter.saveExternalArtwork(artwork, for: item, audioURL: destination) {
                                continuation.yield(.assetCreated(cover))
                            }
                        } catch {
                            artworkTask.cancel()
                            throw error
                        }
                        downloaded += 1
                        outputs.append((item, destination))
                        continuation.yield(.trackCompleted(track: item, destination: destination))
                        continuation.yield(.progress(completedProgress(completed: item.position, total: item.total)))
                    }
                    for booklet in try await assetWriter.downloadBooklets(for: outputs) {
                        continuation.yield(.assetCreated(booklet))
                    }
                    if let playlist = try assetWriter.writePlaylist(plan: plan, outputs: outputs) {
                        continuation.yield(.assetCreated(playlist))
                    }
                    for manifest in try assetWriter.writeChecksumManifests(for: verifiedOutputs) {
                        continuation.yield(.assetCreated(manifest))
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

    private func processingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).processing")
            .appendingPathExtension(destination.pathExtension)
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
