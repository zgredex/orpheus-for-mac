import Foundation

struct QobuzDownloadDestinationResolver: @unchecked Sendable {
    private let outputPlanner: any QobuzOutputPlanning
    private let assetWriter: QobuzCollectionAssetWriter
    private let fileManager: FileManager

    init(
        outputPlanner: any QobuzOutputPlanning,
        assetWriter: QobuzCollectionAssetWriter,
        fileManager: FileManager
    ) {
        self.outputPlanner = outputPlanner
        self.assetWriter = assetWriter
        self.fileManager = fileManager
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
        repairTarget: QobuzArchiveTrack?,
        reusableAudio: [String: URL],
        trackMetadata: [String: String]
    ) throws -> URL {
        if let repairTarget {
            guard fileInfo.formatID == repairTarget.formatID else {
                throw NativeQobuzError.unavailable(
                    "Qobuz no longer offers this track in its archived format. No file was changed."
                )
            }
            let destination = try repairDestination(for: repairTarget, item: item, root: root)
            try validateRepairProvenance(at: destination, target: repairTarget, item: item)
            return destination
        }

        let reuseKey = QobuzFileProvenance.reuseKey(item: item, fileInfo: fileInfo)
        if let reusable = reusableAudio[reuseKey] {
            qobuzLog.notice(
                "download.reuse",
                "Found an existing reusable audio file",
                metadata: trackMetadata.merging(["destinationPath": reusable.path]) { _, new in new }
            )
            return reusable
        }
        return try resolvedDestination(for: item, fileInfo: fileInfo, root: root)
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
        let root = root.standardizedFileURL
        guard let destination = QobuzPathSafety.containedURL(for: target.relativePath, in: root) else {
            throw NativeQobuzError.fileSystem("The archived repair path is unsafe.")
        }
        guard let archivedFormat = target.audioFormat else {
            throw NativeQobuzError.unavailable(
                "The archived Qobuz format \(target.formatID) is not supported for automatic repair."
            )
        }
        guard destination.pathExtension.lowercased() == archivedFormat.fileExtension else {
            throw NativeQobuzError.fileSystem("The archived repair path has the wrong audio extension.")
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedParent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard QobuzPathSafety.isContained(resolvedParent, in: resolvedRoot) else {
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
        let identifier = QobuzFilenameComponent.truncate(
            outputPlanner.sanitize(item.track.id.rawValue),
            toUTF8Bytes: 64
        )
        for collisionIndex in 1...999 {
            let suffix = collisionIndex == 1 ? " [\(identifier)]" : " [\(identifier)-\(collisionIndex)]"
            let candidate = folder.appendingPathComponent(
                QobuzFilenameComponent.make(stem: stem, suffix: suffix, pathExtension: ext)
            )
            guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
            if let provenance = try? assetWriter.provenance(for: candidate), provenance.belongs(to: item) {
                return candidate
            }
        }
        throw NativeQobuzError.fileSystem("Could not resolve a collision-safe output path")
    }
}
