import Foundation

public enum QobuzLibraryManifestAction: String, Equatable, Sendable {
    case none
    case create
    case update
    case repair
}

public struct QobuzLibraryAdoptionPlan: Equatable, Sendable {
    public let root: URL
    public let snapshot: QobuzArchiveSnapshot
    public let manifestAction: QobuzLibraryManifestAction
    public let existingCollectionCount: Int
    public let proposedManifest: QobuzLibraryManifest

    public init(
        root: URL,
        snapshot: QobuzArchiveSnapshot,
        manifestAction: QobuzLibraryManifestAction,
        existingCollectionCount: Int,
        proposedManifest: QobuzLibraryManifest
    ) {
        self.root = root
        self.snapshot = snapshot
        self.manifestAction = manifestAction
        self.existingCollectionCount = existingCollectionCount
        self.proposedManifest = proposedManifest
    }

    public var proposedCollectionCount: Int { proposedManifest.collections.count }
}

public struct QobuzLibraryAdoptionResult: Equatable, Sendable {
    public let plan: QobuzLibraryAdoptionPlan
    public let snapshot: QobuzArchiveSnapshot

    public init(plan: QobuzLibraryAdoptionPlan, snapshot: QobuzArchiveSnapshot) {
        self.plan = plan
        self.snapshot = snapshot
    }
}

public protocol QobuzLibraryAdopting: Sendable {
    func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan
    func adopt(root: URL) async throws -> QobuzLibraryAdoptionResult
}

/// Reconciles the portable, per-folder provenance records with the logical
/// collection index stored at the Library root. Provenance owns physical file
/// identity; the root manifest owns richer logical collection presentation.
public struct QobuzLibraryAdopter: QobuzLibraryAdopting, @unchecked Sendable {
    private let scanner: any QobuzArchiveScanning
    private let fileManager: FileManager

    public init(
        scanner: any QobuzArchiveScanning = QobuzArchiveScanner(),
        fileManager: FileManager = .default
    ) {
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func inspect(root: URL) async throws -> QobuzLibraryAdoptionPlan {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let adoptionID = UUID().uuidString
        let metadata = ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        qobuzLog.notice("library.adoption.inspect", "Existing Library inspection started", metadata: metadata)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            qobuzLog.warning("library.adoption.inspect", "Library candidate is not a folder", metadata: metadata)
            throw NativeQobuzError.fileSystem("The selected Library folder does not exist.")
        }

        let snapshot = try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
            try await scanner.scan(root: root)
        }
        guard !snapshot.tracks.isEmpty else {
            qobuzLog.warning(
                "library.adoption.inspect",
                "Library candidate contains no Orpheus provenance",
                metadata: metadata.merging(["issueCount": String(snapshot.issues.count)]) { _, new in new }
            )
            throw NativeQobuzError.unavailable(
                "No Orpheus provenance records were found in the selected folder."
            )
        }

        let manifestURL = root.appendingPathComponent(QobuzLibraryManifestIO.filename)
        let manifestExists = fileManager.fileExists(atPath: manifestURL.path)
        let existingManifest: QobuzLibraryManifest?
        let unreadableManifest: Bool
        do {
            existingManifest = manifestExists
                ? try QobuzLibraryManifestIO.load(at: root, fileManager: fileManager)
                : nil
            unreadableManifest = false
        } catch {
            existingManifest = nil
            unreadableManifest = true
        }

        let proposed = QobuzLibraryManifest(
            collections: reconciledCollections(
                snapshot: snapshot,
                existing: existingManifest?.collections ?? [],
                root: root
            )
        )
        let action: QobuzLibraryManifestAction
        if unreadableManifest {
            action = .repair
        } else if !manifestExists {
            action = .create
        } else if existingManifest != proposed {
            action = .update
        } else {
            action = .none
        }

        let plan = QobuzLibraryAdoptionPlan(
            root: root,
            snapshot: snapshot,
            manifestAction: action,
            existingCollectionCount: existingManifest?.collections.count ?? 0,
            proposedManifest: proposed
        )
        qobuzLog.notice(
            "library.adoption.inspect",
            "Existing Library inspection completed",
            metadata: metadata.merging([
                "trackCount": String(snapshot.tracks.count),
                "verifiedCount": String(snapshot.verifiedCount),
                "problemCount": String(snapshot.problemCount),
                "existingCollectionCount": String(plan.existingCollectionCount),
                "proposedCollectionCount": String(plan.proposedCollectionCount),
                "manifestAction": action.rawValue
            ]) { _, new in new }
        )
        return plan
    }

    public func adopt(root: URL) async throws -> QobuzLibraryAdoptionResult {
        let plan = try await inspect(root: root)
        let metadata = [
            "candidateRoot": plan.root.path,
            "manifestAction": plan.manifestAction.rawValue,
            "collectionCount": String(plan.proposedCollectionCount)
        ]
        qobuzLog.notice("library.adoption.apply", "Existing Library adoption started", metadata: metadata)
        if plan.manifestAction != .none {
            try QobuzLibraryManifestIO.save(
                plan.proposedManifest,
                at: plan.root,
                fileManager: fileManager
            )
        }

        let verifiedSnapshot = try await scanner.scan(root: plan.root)
        guard verifiedSnapshot.collections == plan.proposedManifest.collections else {
            qobuzLog.error(
                "library.adoption.apply",
                "Adopted Library index did not verify after writing",
                metadata: metadata.merging([
                    "verifiedCollectionCount": String(verifiedSnapshot.collections.count)
                ]) { _, new in new }
            )
            throw NativeQobuzError.fileSystem("The rebuilt Library index did not verify after writing.")
        }
        qobuzLog.notice(
            "library.adoption.apply",
            "Existing Library adoption completed and verified",
            metadata: metadata.merging([
                "trackCount": String(verifiedSnapshot.tracks.count),
                "verifiedCount": String(verifiedSnapshot.verifiedCount),
                "problemCount": String(verifiedSnapshot.problemCount)
            ]) { _, new in new }
        )
        return QobuzLibraryAdoptionResult(plan: plan, snapshot: verifiedSnapshot)
    }

    private func reconciledCollections(
        snapshot: QobuzArchiveSnapshot,
        existing: [QobuzLibraryCollectionRecord],
        root: URL
    ) -> [QobuzLibraryCollectionRecord] {
        let physicalPaths = Set(snapshot.tracks.map(\.relativePath))
        let inferred = inferredCollections(snapshot: snapshot, root: root)
        let inferredByID = Dictionary(inferred.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var records: [String: QobuzLibraryCollectionRecord] = [:]

        for record in existing where isCurrent(record, physicalPaths: physicalPaths, root: root) {
            records[record.id] = record
        }
        for inferredRecord in inferred {
            if let existingRecord = existing.first(where: { $0.id == inferredRecord.id }) {
                records[inferredRecord.id] = mergingPresentation(
                    from: existingRecord,
                    physicalRecord: inferredRecord
                )
            } else if records[inferredRecord.id] == nil {
                records[inferredRecord.id] = inferredRecord
            }
        }

        // A valid logical record can reference canonical files whose physical
        // provenance belongs to another collection (for example a playlist
        // reusing album files). Preserve those records when every path remains
        // present, even if no inference rule can recreate their semantics.
        for record in existing where records[record.id] == nil {
            if isCurrent(record, physicalPaths: physicalPaths, root: root) {
                records[record.id] = record
            } else if let physical = inferredByID[record.id] {
                records[record.id] = mergingPresentation(from: record, physicalRecord: physical)
            }
        }
        return records.values.sorted { $0.id < $1.id }
    }

    private func inferredCollections(
        snapshot: QobuzArchiveSnapshot,
        root: URL
    ) -> [QobuzLibraryCollectionRecord] {
        var records: [QobuzLibraryCollectionRecord] = []
        let albums = Dictionary(
            grouping: snapshot.tracks.filter { $0.archiveKind == .album },
            by: \.qobuzAlbumID
        )
        for albumID in albums.keys.sorted() {
            guard let tracks = albums[albumID], let first = tracks.sorted(by: pathOrder).first else { continue }
            let sortedTracks = tracks.sorted(by: pathOrder)
            let folder = directoryPath(first.relativePath)
            let artist = lastComponent(directoryPath(folder), fallback: "Album")
            let title = lastComponent(folder, fallback: "Album \(albumID)")
            records.append(QobuzLibraryCollectionRecord(
                id: "album|\(albumID)",
                kind: .album,
                qobuzID: albumID,
                title: title,
                subtitle: "\(artist) · \(sortedTracks.count) track\(sortedTracks.count == 1 ? "" : "s")",
                relativePath: folder,
                trackPaths: sortedTracks.map(\.relativePath),
                artworkRelativePath: existingRelativePath(folder: folder, filename: "cover.jpg", root: root)
            ))
        }

        let standalone = Dictionary(
            grouping: snapshot.tracks.filter { $0.archiveKind == .track },
            by: \.qobuzTrackID
        )
        for trackID in standalone.keys.sorted() {
            guard let track = standalone[trackID]?.sorted(by: pathOrder).first else { continue }
            let folder = directoryPath(track.relativePath)
            records.append(QobuzLibraryCollectionRecord(
                id: "track|\(trackID)",
                kind: .track,
                qobuzID: trackID,
                title: filenameTitle(track.relativePath),
                subtitle: lastComponent(folder, fallback: "Standalone track"),
                relativePath: track.relativePath,
                trackPaths: [track.relativePath]
            ))
        }

        records.append(contentsOf: inferredPlaylists(snapshot: snapshot, root: root))
        return records
    }

    private func inferredPlaylists(
        snapshot: QobuzArchiveSnapshot,
        root: URL
    ) -> [QobuzLibraryCollectionRecord] {
        let knownPaths = Set(snapshot.tracks.map(\.relativePath))
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var records: [QobuzLibraryCollectionRecord] = []
        while let playlistURL = enumerator.nextObject() as? URL {
            guard ["m3u", "m3u8"].contains(playlistURL.pathExtension.lowercased()) else { continue }
            let values = try? playlistURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  let contents = try? String(contentsOf: playlistURL, encoding: .utf8) else { continue }
            let folder = playlistURL.deletingLastPathComponent().standardizedFileURL
            var trackPaths: [String] = []
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("/") else { continue }
                let target = URL(fileURLWithPath: line, relativeTo: folder).standardizedFileURL
                guard let relative = try? QobuzLibraryManifestIO.relativePath(of: target, root: root),
                      knownPaths.contains(relative) else { continue }
                trackPaths.append(relative)
            }
            guard !trackPaths.isEmpty,
                  let relativeFolder = try? QobuzLibraryManifestIO.relativePath(of: folder, root: root) else { continue }
            let folderName = folder.lastPathComponent
            let parsed = playlistIdentity(folderName)
            let playlistID = parsed.id ?? relativeFolder
            let descriptionURL = folder.appendingPathComponent("description.txt")
            let description = try? String(contentsOf: descriptionURL, encoding: .utf8)
            records.append(QobuzLibraryCollectionRecord(
                id: "playlist|\(playlistID)",
                kind: .playlist,
                qobuzID: playlistID,
                title: parsed.title.isEmpty ? playlistURL.deletingPathExtension().lastPathComponent : parsed.title,
                subtitle: "Playlist · \(trackPaths.count) track\(trackPaths.count == 1 ? "" : "s")",
                relativePath: relativeFolder,
                trackPaths: trackPaths,
                artworkRelativePath: existingRelativePath(folder: relativeFolder, filename: "cover.jpg", root: root),
                collectionDescription: description?.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceTrackCount: trackPaths.count
            ))
        }
        return records.sorted { $0.id < $1.id }
    }

    private func isCurrent(
        _ record: QobuzLibraryCollectionRecord,
        physicalPaths: Set<String>,
        root: URL
    ) -> Bool {
        let paths = [record.relativePath] + record.trackPaths + [record.artworkRelativePath].compactMap { $0 }
        guard paths.allSatisfy(QobuzLibraryManifestIO.isSafeRelativePath),
              !record.trackPaths.isEmpty,
              record.trackPaths.allSatisfy(physicalPaths.contains) else { return false }
        let collectionURL = root.appendingPathComponent(record.relativePath).standardizedFileURL
        return fileManager.fileExists(atPath: collectionURL.path)
    }

    private func mergingPresentation(
        from existing: QobuzLibraryCollectionRecord,
        physicalRecord: QobuzLibraryCollectionRecord
    ) -> QobuzLibraryCollectionRecord {
        QobuzLibraryCollectionRecord(
            id: physicalRecord.id,
            kind: physicalRecord.kind,
            qobuzID: physicalRecord.qobuzID,
            title: existing.title.isEmpty ? physicalRecord.title : existing.title,
            subtitle: existing.subtitle.isEmpty ? physicalRecord.subtitle : existing.subtitle,
            relativePath: physicalRecord.relativePath,
            trackPaths: physicalRecord.trackPaths,
            artworkRelativePath: physicalRecord.artworkRelativePath ?? existing.artworkRelativePath,
            collectionDescription: existing.collectionDescription ?? physicalRecord.collectionDescription,
            owner: existing.owner,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt,
            duration: existing.duration,
            sourceTrackCount: existing.sourceTrackCount ?? physicalRecord.sourceTrackCount
        )
    }

    private func playlistIdentity(_ folderName: String) -> (title: String, id: String?) {
        guard folderName.hasSuffix("]"),
              let opening = folderName.lastIndex(of: "[") else { return (folderName, nil) }
        let idStart = folderName.index(after: opening)
        let idEnd = folderName.index(before: folderName.endIndex)
        guard idStart < idEnd else { return (folderName, nil) }
        let id = String(folderName[idStart..<idEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(folderName[..<opening]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, id.isEmpty ? nil : id)
    }

    private func existingRelativePath(folder: String, filename: String, root: URL) -> String? {
        guard QobuzLibraryManifestIO.isSafeRelativePath(folder) else { return nil }
        let relative = folder + "/" + filename
        return fileManager.fileExists(atPath: root.appendingPathComponent(relative).path) ? relative : nil
    }

    private func directoryPath(_ path: String) -> String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    private func lastComponent(_ path: String, fallback: String) -> String {
        guard !path.isEmpty else { return fallback }
        let value = (path as NSString).lastPathComponent
        return value.isEmpty || value == "." ? fallback : value
    }

    private func filenameTitle(_ path: String) -> String {
        var value = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let range = value.range(of: #"^\d+(?:-\d+)?\.\s*"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value.isEmpty ? "Track" : value
    }

    private func pathOrder(_ lhs: QobuzArchiveTrack, _ rhs: QobuzArchiveTrack) -> Bool {
        lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}
