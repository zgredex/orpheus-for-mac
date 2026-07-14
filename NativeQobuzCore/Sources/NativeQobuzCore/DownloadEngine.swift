import Foundation

public struct QobuzDownloadProgress: Equatable, Sendable {
    public let completedTracks: Int
    public let totalTracks: Int
    public let currentTrackFraction: Double?
    public let overallFraction: Double
    public let bytesWritten: Int64?
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?
    /// Bytes downloaded so far across the whole plan (album/playlist),
    /// including the partially transferred current track.
    public let albumBytesWritten: Int64?

    public init(
        completedTracks: Int,
        totalTracks: Int,
        currentTrackFraction: Double?,
        overallFraction: Double,
        bytesWritten: Int64?,
        totalBytes: Int64?,
        bytesPerSecond: Double?,
        albumBytesWritten: Int64? = nil
    ) {
        self.completedTracks = completedTracks
        self.totalTracks = totalTracks
        self.currentTrackFraction = currentTrackFraction
        self.overallFraction = min(max(overallFraction.isFinite ? overallFraction : 0, 0), 1)
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.albumBytesWritten = albumBytesWritten
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
    case warning(String)
    case trackCompleted(track: QobuzResolvedTrack, destination: URL)
    case trackSkipped(track: QobuzResolvedTrack, destination: URL)
    case completed(title: String, downloaded: Int, skipped: Int)
}

/// Stable locations used while an audio download is being processed.
///
/// The transfer client appends `.partial` to the processing URL and preserves
/// that file when a transfer is interrupted. Keeping this calculation public
/// lets clients accurately report resumable work without duplicating the
/// engine's filename rules.
public enum QobuzDownloadArtifacts {
    public static func processingURL(for destination: URL, formatID: Int) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.deletingPathExtension().lastPathComponent).qobuz-\(formatID).processing"
            )
            .appendingPathExtension(destination.pathExtension)
    }

    public static func partialURL(for destination: URL, formatID: Int) -> URL {
        processingURL(for: destination, formatID: formatID)
            .appendingPathExtension("partial")
    }
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
        downloadRoot: URL,
        includedTrackIDs: Set<QobuzID>? = nil
    ) -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        makeEvents(
            for: request,
            quality: quality,
            downloadRoot: downloadRoot,
            repairTarget: nil,
            includedTrackIDs: includedTrackIDs
        )
    }

    public func repairEvents(
        for target: QobuzArchiveTrack,
        downloadRoot: URL
    ) throws -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        guard let quality = QobuzQuality(formatID: target.formatID) else {
            throw NativeQobuzError.unavailable(
                "The archived Qobuz format \(target.formatID) is not supported for automatic repair."
            )
        }
        return makeEvents(
            for: .track(QobuzID(target.qobuzTrackID)),
            quality: quality,
            downloadRoot: downloadRoot,
            repairTarget: target,
            includedTrackIDs: nil
        )
    }

    private func makeEvents(
        for request: QobuzRequest,
        quality: QobuzQuality,
        downloadRoot: URL,
        repairTarget: QobuzArchiveTrack?,
        includedTrackIDs: Set<QobuzID>?
    ) -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        let operationID = UUID().uuidString
        let operationMetadata = [
            "downloadOperationID": operationID,
            "requestKind": request.kindName,
            "qobuzID": request.id.rawValue,
            "quality": quality.rawValue,
            "formatID": String(quality.formatID),
            "downloadRoot": downloadRoot.path,
            "repair": String(repairTarget != nil),
            "selectedTrackCount": includedTrackIDs.map { String($0.count) } ?? "all"
        ]
        return AsyncThrowingStream { continuation in
            let task = Task {
                await QobuzLogScope.withValue(operationMetadata) {
                  let operationStarted = Date()
                  qobuzLog.notice("download.lifecycle", "Download operation started")
                  do {
                    continuation.yield(.resolving(request))
                    let plan = try await resolver.resolve(request)
                        .selecting(trackIDs: includedTrackIDs)
                    try Task.checkCancellation()
                    if let repairTarget {
                        try validateRepairPlan(plan, target: repairTarget)
                    }
                    qobuzLog.info(
                        "download.plan",
                        "Download plan accepted",
                        metadata: ["title": plan.title, "trackCount": String(plan.tracks.count)]
                    )
                    continuation.yield(.planReady(title: plan.title, trackCount: plan.tracks.count))

                    var downloaded = 0
                    var skipped = 0
                    var albumBytes: Int64 = 0
                    var currentTrackBytes: Int64 = 0
                    var outputs: [(item: QobuzResolvedTrack, audioURL: URL)] = []
                    var verifiedOutputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)] = []
                    var reusableAudio: [String: URL]
                    do {
                        reusableAudio = try assetWriter.reusableAudioIndex(root: downloadRoot)
                        qobuzLog.debug(
                            "download.reuse",
                            "Reusable audio index loaded",
                            metadata: ["candidateCount": String(reusableAudio.count)]
                        )
                    } catch {
                        reusableAudio = [:]
                        qobuzLog.warning(
                            "download.reuse",
                            "Reusable audio index could not be loaded; continuing without reuse",
                            error: error
                        )
                    }
                    var artworkCache: [QobuzID: EmbeddedArtwork] = [:]
                    var albumsWithoutArtwork = Set<QobuzID>()
                    for item in plan.tracks {
                        try Task.checkCancellation()
                        let trackMetadata = [
                            "trackID": item.track.id.rawValue,
                            "albumID": item.album.id.rawValue,
                            "trackTitle": item.track.displayTitle,
                            "position": String(item.position),
                            "totalTracks": String(item.total)
                        ]
                        let trackStarted = Date()
                        qobuzLog.info("download.track", "Resolving downloadable audio file", metadata: trackMetadata)
                        let fileInfo = try await QobuzLogScope.withValue(trackMetadata) {
                            try await service.fileInfo(trackID: item.track.id, quality: quality)
                        }
                        qobuzLog.debug(
                            "download.track",
                            "Downloadable audio file resolved",
                            metadata: trackMetadata.merging([
                                "sourceHost": fileInfo.url.host ?? "unknown",
                                "formatID": String(fileInfo.formatID)
                            ]) { _, new in new }
                        )
                        let destination: URL
                        if let repairTarget {
                            guard fileInfo.formatID == repairTarget.formatID else {
                                throw NativeQobuzError.unavailable(
                                    "Qobuz no longer offers this track in its archived format. No file was changed."
                                )
                            }
                            destination = try repairDestination(
                                for: repairTarget,
                                item: item,
                                root: downloadRoot
                            )
                            try validateRepairProvenance(
                                at: destination,
                                target: repairTarget,
                                item: item
                            )
                        } else {
                            let reuseKey = QobuzFileProvenance.reuseKey(item: item, fileInfo: fileInfo)
                            if let reusable = reusableAudio[reuseKey] {
                                destination = reusable
                                qobuzLog.notice(
                                    "download.reuse",
                                    "Found an existing reusable audio file",
                                    metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new }
                                )
                            } else {
                                destination = try resolvedDestination(for: item, fileInfo: fileInfo, root: downloadRoot)
                            }
                        }
                        qobuzLog.debug(
                            "download.output",
                            "Track output path selected",
                            metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new }
                        )

                        if fileManager.fileExists(atPath: destination.path),
                           let provenance = try? assetWriter.provenance(for: destination),
                           provenance.matches(item: item, fileInfo: fileInfo) {
                            do {
                                continuation.yield(.validating(track: item))
                                try await validator.validate(destination)
                                try Task.checkCancellation()
                                let checksum = try MusicFileIntegrity.sha256(of: destination)
                                if provenance.sha256.caseInsensitiveCompare(checksum) != .orderedSame {
                                    throw NativeQobuzError.invalidResponse("Existing file checksum does not match")
                                }
                                try assetWriter.recordProvenance(
                                    QobuzFileProvenance(
                                        item: item,
                                        fileInfo: fileInfo,
                                        sha256: checksum,
                                        archiveKind: repairTarget?.archiveKind
                                            ?? (provenance.archiveKind == .unclassified
                                                ? nil
                                                : provenance.archiveKind)
                                    ),
                                    for: destination
                                )
                                let size = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
                                albumBytes += size?.int64Value ?? 0
                                skipped += 1
                                outputs.append((item, destination))
                                verifiedOutputs.append((item, destination, checksum))
                                reusableAudio[QobuzFileProvenance.reuseKey(item: item, fileInfo: fileInfo)] = destination
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
                                        completedProgress(
                                            completed: item.position,
                                            total: item.total,
                                            albumBytes: albumBytes
                                        )
                                    )
                                )
                                continue
                            } catch is CancellationError {
                                throw NativeQobuzError.cancelled
                            } catch NativeQobuzError.cancelled {
                                throw NativeQobuzError.cancelled
                            } catch {
                                qobuzLog.warning(
                                    "download.reuse",
                                    "Existing audio failed verification and will be downloaded again",
                                    metadata: trackMetadata.merging(["destinationPath": destination.path]) { _, new in new },
                                    error: error
                                )
                            }
                        }

                        continuation.yield(.trackStarted(track: item, destination: destination))
                        let artworkTask: Task<EmbeddedArtwork?, Error>
                        if let cached = artworkCache[item.album.id] {
                            artworkTask = Task { cached }
                        } else if albumsWithoutArtwork.contains(item.album.id) {
                            artworkTask = Task { nil }
                        } else {
                            artworkTask = Task {
                                try await QobuzLogScope.withValue(trackMetadata) {
                                    try await assetWriter.artwork(for: item.album)
                                }
                            }
                        }
                        let staging = QobuzDownloadArtifacts.processingURL(
                            for: destination,
                            formatID: fileInfo.formatID
                        )
                        defer {
                            if fileManager.fileExists(atPath: staging.path) {
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
                        }
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
                                switch transferEvent {
                                case .started, .completed:
                                    break
                                case .progress(let progress):
                                    let fileFraction = progress.fraction
                                    let overall = (
                                        Double(item.position - 1) + (fileFraction ?? 0)
                                    ) / Double(max(item.total, 1))
                                    currentTrackBytes = progress.bytesWritten
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
                                                albumBytesWritten: albumBytes + currentTrackBytes
                                            )
                                        )
                                    )
                                }
                            }
                            qobuzLog.info("download.transfer", "Track audio transfer finished", metadata: trackMetadata)
                            let artwork: EmbeddedArtwork?
                            do {
                                artwork = try await artworkTask.value
                            } catch is CancellationError {
                                throw NativeQobuzError.cancelled
                            } catch NativeQobuzError.cancelled {
                                throw NativeQobuzError.cancelled
                            } catch {
                                albumsWithoutArtwork.insert(item.album.id)
                                artwork = nil
                                qobuzLog.warning(
                                    "download.artwork",
                                    "Album artwork could not be downloaded",
                                    metadata: trackMetadata,
                                    error: error
                                )
                                continuation.yield(.warning("Artwork: \(error.localizedDescription)"))
                            }
                            if let artwork {
                                artworkCache[item.album.id] = artwork
                            } else {
                                albumsWithoutArtwork.insert(item.album.id)
                            }
                            continuation.yield(.tagging(track: item))
                            qobuzLog.info("download.metadata", "Writing audio metadata and artwork", metadata: trackMetadata)
                            try metadataWriter.write(metadata: QobuzAudioMetadata(item: item), artwork: artwork, to: staging)
                            qobuzLog.debug("download.metadata", "Audio metadata written", metadata: trackMetadata)
                            continuation.yield(.validating(track: item))
                            try await validator.validate(staging)
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
                                    fileInfo: fileInfo,
                                    sha256: checksum,
                                    archiveKind: repairTarget?.archiveKind
                                ),
                                for: destination
                            )
                            verifiedOutputs.append((item, destination, checksum))
                            reusableAudio[QobuzFileProvenance.reuseKey(item: item, fileInfo: fileInfo)] = destination
                            continuation.yield(.integrityVerified(track: item, sha256: checksum))
                            if let artwork {
                                do {
                                    if let cover = try assetWriter.saveExternalArtwork(
                                        artwork,
                                        for: item,
                                        audioURL: destination
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
                        } catch {
                            artworkTask.cancel()
                            throw error
                        }
                        let installedSize = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
                        albumBytes += installedSize?.int64Value ?? currentTrackBytes
                        currentTrackBytes = 0
                        downloaded += 1
                        outputs.append((item, destination))
                        qobuzLog.notice(
                            "download.track",
                            "Track download completed",
                            metadata: trackMetadata.merging([
                                "destinationPath": destination.path,
                                "durationMs": String(Int(Date().timeIntervalSince(trackStarted) * 1_000))
                            ]) { _, new in new }
                        )
                        continuation.yield(.trackCompleted(track: item, destination: destination))
                        continuation.yield(.progress(completedProgress(completed: item.position, total: item.total, albumBytes: albumBytes)))
                    }
                    do {
                        for booklet in try await assetWriter.downloadBooklets(for: outputs) {
                            qobuzLog.info(
                                "download.asset",
                                "Booklet downloaded",
                                metadata: ["assetPath": booklet.path]
                            )
                            continuation.yield(.assetCreated(booklet))
                        }
                    } catch is CancellationError {
                        throw NativeQobuzError.cancelled
                    } catch NativeQobuzError.cancelled {
                        throw NativeQobuzError.cancelled
                    } catch {
                        qobuzLog.warning("download.asset", "Booklet download failed", error: error)
                        continuation.yield(.warning("Booklet: \(error.localizedDescription)"))
                    }
                    try Task.checkCancellation()
                    do {
                        for description in try assetWriter.writeAlbumDescriptions(for: outputs) {
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
                    try Task.checkCancellation()
                    do {
                        if let playlist = try assetWriter.writePlaylist(
                            plan: plan,
                            outputs: outputs,
                            downloadRoot: downloadRoot
                        ) {
                            qobuzLog.info(
                                "download.asset",
                                "Playlist file written",
                                metadata: ["assetPath": playlist.path]
                            )
                            continuation.yield(.assetCreated(playlist))
                        }
                    } catch {
                        qobuzLog.warning("download.asset", "Playlist file could not be written", error: error)
                        continuation.yield(.warning("Playlist: \(error.localizedDescription)"))
                    }
                    try Task.checkCancellation()
                    do {
                        for manifest in try assetWriter.writeChecksumManifests(for: verifiedOutputs) {
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
                    try Task.checkCancellation()
                    do {
                        for asset in try await assetWriter.writePlaylistMetadata(
                            plan: plan,
                            downloadRoot: downloadRoot
                        ) {
                            qobuzLog.info(
                                "download.asset",
                                "Playlist metadata asset written",
                                metadata: ["assetPath": asset.path]
                            )
                            continuation.yield(.assetCreated(asset))
                        }
                    } catch is CancellationError {
                        throw NativeQobuzError.cancelled
                    } catch NativeQobuzError.cancelled {
                        throw NativeQobuzError.cancelled
                    } catch {
                        qobuzLog.warning("download.asset", "Playlist metadata could not be written", error: error)
                        continuation.yield(.warning("Playlist metadata: \(error.localizedDescription)"))
                    }
                    if repairTarget == nil {
                        try Task.checkCancellation()
                        do {
                            let manifest = try assetWriter.recordLibraryCollections(
                                plan: plan,
                                outputs: outputs,
                                downloadRoot: downloadRoot
                            )
                            try assetWriter.markLibraryManaged(outputs.map(\.audioURL))
                            qobuzLog.notice(
                                "download.library",
                                "Library manifest updated",
                                metadata: [
                                    "manifestPath": manifest.path,
                                    "outputCount": String(outputs.count)
                                ]
                            )
                            continuation.yield(.assetCreated(manifest))
                        } catch {
                            qobuzLog.warning("download.library", "Library manifest could not be updated", error: error)
                            continuation.yield(.warning("Library manifest: \(error.localizedDescription)"))
                        }
                    }
                    qobuzLog.notice(
                        "download.lifecycle",
                        "Download operation completed",
                        metadata: [
                            "title": plan.title,
                            "downloaded": String(downloaded),
                            "skipped": String(skipped),
                            "outputCount": String(outputs.count),
                            "durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))
                        ]
                    )
                    continuation.yield(.completed(title: plan.title, downloaded: downloaded, skipped: skipped))
                    continuation.finish()
                } catch is CancellationError {
                    qobuzLog.notice(
                        "download.lifecycle",
                        "Download operation cancelled",
                        metadata: ["durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))]
                    )
                    continuation.finish(throwing: NativeQobuzError.cancelled)
                } catch {
                    if let native = error as? NativeQobuzError, case .cancelled = native {
                        qobuzLog.notice(
                            "download.lifecycle",
                            "Download operation cancelled",
                            metadata: ["durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))]
                        )
                    } else {
                        qobuzLog.error(
                            "download.lifecycle",
                            "Download operation failed",
                            metadata: ["durationMs": String(Int(Date().timeIntervalSince(operationStarted) * 1_000))],
                            error: error
                        )
                    }
                    continuation.finish(throwing: error)
                }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func validateRepairPlan(
        _ plan: QobuzDownloadPlan,
        target: QobuzArchiveTrack
    ) throws {
        guard plan.tracks.count == 1,
              let item = plan.tracks.first,
              item.track.id.rawValue == target.qobuzTrackID,
              item.album.id.rawValue == target.qobuzAlbumID else {
            throw NativeQobuzError.unavailable(
                "Qobuz metadata no longer matches this archive record. Refresh the Library before retrying."
            )
        }
    }

    private func repairDestination(
        for target: QobuzArchiveTrack,
        item: QobuzResolvedTrack,
        root: URL
    ) throws -> URL {
        guard item.track.id.rawValue == target.qobuzTrackID,
              item.album.id.rawValue == target.qobuzAlbumID else {
            throw NativeQobuzError.unavailable("The repair target no longer matches Qobuz metadata.")
        }
        let components = target.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !target.relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NativeQobuzError.fileSystem("The archived repair path is unsafe.")
        }

        let root = root.standardizedFileURL
        let destination = root.appendingPathComponent(target.relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw NativeQobuzError.fileSystem("The archived repair path escapes the download folder.")
        }
        let expectedExtension = target.formatID == QobuzQuality.mp3.formatID ? "mp3" : "flac"
        guard destination.pathExtension.lowercased() == expectedExtension else {
            throw NativeQobuzError.fileSystem("The archived repair path has the wrong audio extension.")
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedParent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolvedPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedParent.path == resolvedRoot.path || resolvedParent.path.hasPrefix(resolvedPrefix) else {
            throw NativeQobuzError.fileSystem("The archived repair path follows a link outside the download folder.")
        }
        if fileManager.fileExists(atPath: destination.path),
           (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw NativeQobuzError.fileSystem("Symbolic-link audio files cannot be repaired automatically.")
        }
        return destination
    }

    private func validateRepairProvenance(
        at destination: URL,
        target: QobuzArchiveTrack,
        item: QobuzResolvedTrack
    ) throws {
        let provenance: QobuzFileProvenance
        do {
            guard let value = try assetWriter.provenance(for: destination) else {
                throw NativeQobuzError.invalidResponse("The archive record changed after verification.")
            }
            provenance = value
        } catch let error as NativeQobuzError {
            throw error
        } catch {
            throw NativeQobuzError.invalidResponse("Could not re-check repair provenance: \(error.localizedDescription)")
        }
        guard provenance.belongs(to: item),
              provenance.qobuzTrackID == target.qobuzTrackID,
              provenance.qobuzAlbumID == target.qobuzAlbumID,
              provenance.formatID == target.formatID else {
            throw NativeQobuzError.unavailable(
                "The archive record changed after verification. Refresh the Library before retrying."
            )
        }
    }

    private func resolvedDestination(
        for item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        root: URL
    ) throws -> URL {
        let planned = outputPlanner.destination(for: item, fileInfo: fileInfo, root: root)
        guard fileManager.fileExists(atPath: planned.path) else { return planned }
        if let provenance = try? assetWriter.provenance(for: planned), provenance.belongs(to: item) {
            return planned
        }

        let folder = planned.deletingLastPathComponent()
        let stem = planned.deletingPathExtension().lastPathComponent
        let ext = planned.pathExtension
        let identifier = StandardQobuzOutputPlanner().sanitize(item.track.id.rawValue)
        for collisionIndex in 1...999 {
            let suffix = collisionIndex == 1 ? " [\(identifier)]" : " [\(identifier)-\(collisionIndex)]"
            let candidate = folder.appendingPathComponent("\(stem)\(suffix).\(ext)")
            guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
            if let provenance = try? assetWriter.provenance(for: candidate), provenance.belongs(to: item) {
                return candidate
            }
        }
        throw NativeQobuzError.fileSystem("Could not resolve a collision-safe output path")
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

    private func completedProgress(completed: Int, total: Int, albumBytes: Int64) -> QobuzDownloadProgress {
        QobuzDownloadProgress(
            completedTracks: completed,
            totalTracks: total,
            currentTrackFraction: 1,
            overallFraction: Double(completed) / Double(max(total, 1)),
            bytesWritten: nil,
            totalBytes: nil,
            bytesPerSecond: nil,
            albumBytesWritten: albumBytes
        )
    }
}
