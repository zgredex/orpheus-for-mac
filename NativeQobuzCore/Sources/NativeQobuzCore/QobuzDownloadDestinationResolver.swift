import Foundation

struct QobuzDownloadDestinationResolver: @unchecked Sendable {
    private let outputPlanner: any QobuzOutputPlanning
    private let assetWriter: QobuzCollectionAssetWriter
    private let reuseRegistry: QobuzAudioReuseRegistry

    init(
        outputPlanner: any QobuzOutputPlanning,
        assetWriter: QobuzCollectionAssetWriter,
        reuseRegistry: QobuzAudioReuseRegistry
    ) {
        self.outputPlanner = outputPlanner
        self.assetWriter = assetWriter
        self.reuseRegistry = reuseRegistry
    }

    func validate(plan: QobuzDownloadPlan, repairTarget: QobuzArchiveTrack?) throws {
        guard let target = repairTarget else { return }
        guard plan.tracks.count == 1,
              let item = plan.tracks.first,
              item.track.id.rawValue == target.qobuzTrackID,
              item.album.id.rawValue == target.qobuzAlbumID else {
            throw NativeQobuzError.unavailable(
                "Qobuz metadata no longer matches this archive record. Refresh the Library before retrying."
            )
        }
    }

    func destination(
        for item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        root: URL,
        fileSystem: LibraryFileSystem,
        repairTarget: QobuzArchiveTrack?,
        reusableAudio: inout [String: URL],
        trackMetadata: [String: String]
    ) throws -> URL {
        if let repairTarget {
            guard fileInfo.formatID == repairTarget.formatID else {
                throw NativeQobuzError.unavailable(
                    "Qobuz no longer offers this track in its archived format. No file was changed."
                )
            }
            let destination = try repairDestination(for: repairTarget, item: item, fileSystem: fileSystem)
            try validateRepairProvenance(
                at: destination,
                target: repairTarget,
                item: item,
                fileSystem: fileSystem
            )
            return destination
        }

        let reuseKey = QobuzFileProvenance.reuseKey(item: item, fileInfo: fileInfo)
        if let reusable = reusableAudio[reuseKey] {
            let path = try? fileSystem.relativePath(for: reusable)
            let provenance = try? assetWriter.provenance(for: reusable, fileSystem: fileSystem)
            if let path,
               try fileSystem.metadata(at: path)?.kind == .regularFile,
               provenance?.matchesIdentityAndFormat(item: item, fileInfo: fileInfo) == true {
                qobuzLog.notice(
                    "download.reuse",
                    "Found an existing reusable audio file",
                    metadata: trackMetadata.merging(["destinationPath": reusable.path]) { _, new in new }
                )
                return reusable
            }
            reusableAudio[reuseKey] = nil
            reuseRegistry.remove(reuseKey: reuseKey, root: root)
            qobuzLog.warning(
                "download.reuse",
                "Discarded a stale reusable-audio cache entry before destination planning",
                metadata: trackMetadata.merging(["candidatePath": reusable.path]) { _, new in new }
            )
        }
        return try resolvedDestination(for: item, fileInfo: fileInfo, root: root, fileSystem: fileSystem)
    }

    private func repairDestination(
        for target: QobuzArchiveTrack,
        item: QobuzResolvedTrack,
        fileSystem: LibraryFileSystem
    ) throws -> URL {
        guard item.track.id.rawValue == target.qobuzTrackID,
              item.album.id.rawValue == target.qobuzAlbumID else {
            throw NativeQobuzError.unavailable("The repair target no longer matches Qobuz metadata.")
        }
        let path = try LibraryRelativePath(target.relativePath)
        guard let archivedFormat = target.audioFormat else {
            throw NativeQobuzError.unavailable(
                "The archived Qobuz format \(target.formatID) is not supported for automatic repair."
            )
        }
        guard (path.lastComponent! as NSString).pathExtension.lowercased() == archivedFormat.fileExtension else {
            throw NativeQobuzError.fileSystem("The archived repair path has the wrong audio extension.")
        }
        if try fileSystem.metadata(at: path)?.kind == .symbolicLink {
            throw NativeQobuzError.fileSystem("Symbolic-link audio files cannot be repaired automatically.")
        }
        return fileSystem.displayURL(for: path)
    }

    private func validateRepairProvenance(
        at destination: URL,
        target: QobuzArchiveTrack,
        item: QobuzResolvedTrack,
        fileSystem: LibraryFileSystem
    ) throws {
        let provenance: QobuzFileProvenance
        do {
            guard let value = try assetWriter.provenance(for: destination, fileSystem: fileSystem) else {
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
              provenance.formatID == target.formatID,
              provenance.bitDepth == target.bitDepth,
              ratesMatch(provenance.samplingRate, target.samplingRate),
              provenance.sha256.caseInsensitiveCompare(target.expectedSHA256) == .orderedSame,
              provenance.archiveKind == target.archiveKind,
              provenance.isLibraryManaged == target.isLibraryManaged else {
            throw NativeQobuzError.unavailable(
                "The archive record changed after verification. Refresh the Library before retrying."
            )
        }
        let path = try fileSystem.relativePath(for: destination)
        let metadata = try fileSystem.metadata(at: path)
        if target.integrity == .missing {
            guard metadata == nil else { throw staleRepairTarget() }
            return
        }
        guard let metadata, metadata.kind == .regularFile else { throw staleRepairTarget() }
        if let byteCount = target.byteCount, metadata.byteCount != byteCount { throw staleRepairTarget() }
        if let modified = target.modificationDate,
           abs(metadata.modificationDate.timeIntervalSince(modified)) > 0.001 {
            throw staleRepairTarget()
        }
        if let actualSHA256 = target.actualSHA256 {
            let current = try MusicFileIntegrity.sha256(of: path, in: fileSystem)
            guard current.caseInsensitiveCompare(actualSHA256) == .orderedSame else {
                throw staleRepairTarget()
            }
        }
    }

    private func ratesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) < 0.01
        default: false
        }
    }

    private func staleRepairTarget() -> NativeQobuzError {
        .unavailable("The repair target changed after verification. Refresh the Library before retrying.")
    }

    private func resolvedDestination(
        for item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        root: URL,
        fileSystem: LibraryFileSystem
    ) throws -> URL {
        let planned = outputPlanner.destination(for: item, fileInfo: fileInfo, root: root)
        let plannedPath = try fileSystem.relativePath(for: planned)
        guard try fileSystem.metadata(at: plannedPath) != nil else { return planned }
        if let provenance = try? assetWriter.provenance(for: planned, fileSystem: fileSystem),
           provenance.belongs(to: item) {
            return planned
        }

        let folder = planned.deletingLastPathComponent()
        let stem = planned.deletingPathExtension().lastPathComponent
        let ext = planned.pathExtension
        let identifier = QobuzFilenameComponent.truncate(
            outputPlanner.sanitize(item.track.id.rawValue),
            toUTF8Bytes: 64
        )
        for collisionIndex in 1...999 {
            let suffix = collisionIndex == 1 ? " [\(identifier)]" : " [\(identifier)-\(collisionIndex)]"
            let candidate = folder.appendingPathComponent(
                QobuzFilenameComponent.make(stem: stem, suffix: suffix, pathExtension: ext)
            )
            let candidatePath = try fileSystem.relativePath(for: candidate)
            guard try fileSystem.metadata(at: candidatePath) != nil else { return candidate }
            if let provenance = try? assetWriter.provenance(for: candidate, fileSystem: fileSystem),
               provenance.belongs(to: item) {
                return candidate
            }
        }
        throw NativeQobuzError.fileSystem("Could not resolve a collision-safe output path")
    }
}
