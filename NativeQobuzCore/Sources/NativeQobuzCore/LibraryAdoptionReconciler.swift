import Foundation

struct QobuzLibraryCollectionReconciler {
    let fileSystem: LibraryFileSystem

    func reconcile(
        snapshot: QobuzArchiveSnapshot,
        existing: [QobuzLibraryCollectionRecord]
    ) throws -> [QobuzLibraryCollectionRecord] {
        let physicalPaths = Set(snapshot.tracks.map(\.relativePath))
        let inferred = try inferredCollections(snapshot: snapshot)
        let inferredByID = Dictionary(inferred.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var records: [String: QobuzLibraryCollectionRecord] = [:]

        for record in existing {
            if try isCurrent(record, physicalPaths: physicalPaths) {
                records[record.id] = record
            }
        }
        for inferredRecord in inferred {
            if let existingRecord = existing.first(where: { $0.id == inferredRecord.id }) {
                records[inferredRecord.id] = mergingPresentation(from: existingRecord, physicalRecord: inferredRecord)
            } else if records[inferredRecord.id] == nil {
                records[inferredRecord.id] = inferredRecord
            }
        }
        for record in existing where records[record.id] == nil {
            if try isCurrent(record, physicalPaths: physicalPaths) {
                records[record.id] = record
            } else if let physical = inferredByID[record.id] {
                records[record.id] = mergingPresentation(from: record, physicalRecord: physical)
            }
        }
        return records.values.sorted { $0.id < $1.id }
    }

    private func inferredCollections(snapshot: QobuzArchiveSnapshot) throws -> [QobuzLibraryCollectionRecord] {
        var records: [QobuzLibraryCollectionRecord] = []
        let albums = Dictionary(grouping: snapshot.tracks.filter { $0.archiveKind == .album }, by: \.qobuzAlbumID)
        for albumID in albums.keys.sorted() {
            guard let tracks = albums[albumID], let first = tracks.sorted(by: pathOrder).first else { continue }
            let sortedTracks = tracks.sorted(by: pathOrder)
            let folder = QobuzPathSafety.directoryPath(of: first.relativePath)
            records.append(QobuzLibraryRecordFactory.album(
                qobuzID: albumID,
                title: QobuzPathSafety.lastComponent(of: folder, fallback: "Album \(albumID)"),
                artist: QobuzPathSafety.lastComponent(
                    of: QobuzPathSafety.directoryPath(of: folder),
                    fallback: "Album"
                ),
                relativePath: folder,
                trackPaths: sortedTracks.map(\.relativePath),
                artworkRelativePath: try existingArtworkRelativePath(folder: folder)
            ))
        }

        let standalone = Dictionary(grouping: snapshot.tracks.filter { $0.archiveKind == .track }, by: \.qobuzTrackID)
        for trackID in standalone.keys.sorted() {
            guard let track = standalone[trackID]?.sorted(by: pathOrder).first else { continue }
            let folder = QobuzPathSafety.directoryPath(of: track.relativePath)
            records.append(QobuzLibraryRecordFactory.track(
                qobuzID: trackID,
                title: filenameTitle(track.relativePath),
                artist: QobuzPathSafety.lastComponent(of: folder, fallback: "Standalone track"),
                relativePath: track.relativePath,
                artworkRelativePath: try existingArtworkRelativePath(folder: folder)
            ))
        }
        records.append(contentsOf: try QobuzLibraryPlaylistInference(fileSystem: fileSystem).infer(snapshot: snapshot))
        return records
    }

    private func isCurrent(
        _ record: QobuzLibraryCollectionRecord,
        physicalPaths: Set<String>
    ) throws -> Bool {
        let paths = [record.relativePath] + record.trackPaths + [record.artworkRelativePath].compactMap { $0 }
        guard paths.allSatisfy(QobuzPathSafety.isSafeRelativePath),
              !record.trackPaths.isEmpty,
              record.trackPaths.allSatisfy(physicalPaths.contains) else { return false }
        let path = try LibraryRelativePath(record.relativePath)
        guard let metadata = try fileSystem.metadata(at: path) else { return false }
        return metadata.kind != .symbolicLink
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

    private func existingArtworkRelativePath(folder: String) throws -> String? {
        let folderPath = try LibraryRelativePath(folder)
        for filename in EmbeddedArtwork.externalFilenames {
            let path = try folderPath.appending(filename)
            guard let metadata = try fileSystem.metadata(at: path),
                  metadata.kind == .regularFile else { continue }
            return path.rawValue
        }
        return nil
    }

    private func filenameTitle(_ path: String) -> String {
        var value = QobuzPathSafety.filenameStem(of: path)
        if let range = value.range(of: #"^\d+(?:-\d+)?\.\s*"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value.isEmpty ? "Track" : value
    }

    private func pathOrder(_ lhs: QobuzArchiveTrack, _ rhs: QobuzArchiveTrack) -> Bool {
        lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}
