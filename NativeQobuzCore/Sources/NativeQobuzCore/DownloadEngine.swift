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
        makeEvents(
            for: request,
            quality: quality,
            downloadRoot: downloadRoot,
            repairTarget: nil
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
            repairTarget: target
        )
    }

    private func makeEvents(
        for request: QobuzRequest,
        quality: QobuzQuality,
        downloadRoot: URL,
        repairTarget: QobuzArchiveTrack?
    ) -> AsyncThrowingStream<QobuzDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.resolving(request))
                    let plan = try await resolver.resolve(request)
                    try Task.checkCancellation()
                    if let repairTarget {
                        try validateRepairPlan(plan, target: repairTarget)
                    }
                    continuation.yield(.planReady(title: plan.title, trackCount: plan.tracks.count))

                    var downloaded = 0
                    var skipped = 0
                    var albumBytes: Int64 = 0
                    var currentTrackBytes: Int64 = 0
                    var outputs: [(item: QobuzResolvedTrack, audioURL: URL)] = []
                    var verifiedOutputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)] = []
                    var reusableAudio = (try? assetWriter.reusableAudioIndex(root: downloadRoot)) ?? [:]
                    var artworkCache: [QobuzID: EmbeddedArtwork] = [:]
                    var albumsWithoutArtwork = Set<QobuzID>()
                    for item in plan.tracks {
                        try Task.checkCancellation()
                        let fileInfo = try await service.fileInfo(trackID: item.track.id, quality: quality)
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
                            } else {
                                destination = try resolvedDestination(for: item, fileInfo: fileInfo, root: downloadRoot)
                            }
                        }

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
                            } catch {}
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
                        let staging = processingURL(for: destination, formatID: fileInfo.formatID)
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
                                continuation.yield(.warning("Artwork: \(error.localizedDescription)"))
                            }
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
                        continuation.yield(.trackCompleted(track: item, destination: destination))
                        continuation.yield(.progress(completedProgress(completed: item.position, total: item.total, albumBytes: albumBytes)))
                    }
                    do {
                        for booklet in try await assetWriter.downloadBooklets(for: outputs) {
                            continuation.yield(.assetCreated(booklet))
                        }
                    } catch is CancellationError {
                        throw NativeQobuzError.cancelled
                    } catch NativeQobuzError.cancelled {
                        throw NativeQobuzError.cancelled
                    } catch {
                        continuation.yield(.warning("Booklet: \(error.localizedDescription)"))
                    }
                    try Task.checkCancellation()
                    do {
                        for description in try assetWriter.writeAlbumDescriptions(for: outputs) {
                            continuation.yield(.assetCreated(description))
                        }
                    } catch {
                        continuation.yield(.warning("Album description: \(error.localizedDescription)"))
                    }
                    try Task.checkCancellation()
                    do {
                        if let playlist = try assetWriter.writePlaylist(
                            plan: plan,
                            outputs: outputs,
                            downloadRoot: downloadRoot
                        ) {
                            continuation.yield(.assetCreated(playlist))
                        }
                    } catch {
                        continuation.yield(.warning("Playlist: \(error.localizedDescription)"))
                    }
                    try Task.checkCancellation()
                    do {
                        for manifest in try assetWriter.writeChecksumManifests(for: verifiedOutputs) {
                            continuation.yield(.assetCreated(manifest))
                        }
                    } catch {
                        continuation.yield(.warning("Checksum manifest: \(error.localizedDescription)"))
                    }
                    try Task.checkCancellation()
                    do {
                        for asset in try await assetWriter.writePlaylistMetadata(
                            plan: plan,
                            downloadRoot: downloadRoot
                        ) {
                            continuation.yield(.assetCreated(asset))
                        }
                    } catch is CancellationError {
                        throw NativeQobuzError.cancelled
                    } catch NativeQobuzError.cancelled {
                        throw NativeQobuzError.cancelled
                    } catch {
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
                            continuation.yield(.assetCreated(manifest))
                        } catch {
                            continuation.yield(.warning("Library manifest: \(error.localizedDescription)"))
                        }
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

    private func processingURL(for destination: URL, formatID: Int) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.deletingPathExtension().lastPathComponent).qobuz-\(formatID).processing"
            )
            .appendingPathExtension(destination.pathExtension)
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
