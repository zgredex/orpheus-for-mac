import Foundation

struct QobuzLibraryPlaylistInference {
    let fileSystem: LibraryFileSystem

    func infer(snapshot: QobuzArchiveSnapshot) throws -> [QobuzLibraryCollectionRecord] {
        let knownPaths = Set(snapshot.tracks.map(\.relativePath))
        let directorySnapshot = try fileSystem.recursiveSnapshot()
        var records: [QobuzLibraryCollectionRecord] = []
        for entry in directorySnapshot.entries {
            if let record = try playlistRecord(for: entry, knownPaths: knownPaths) {
                records.append(record)
            }
        }
        return records.sorted { $0.id < $1.id }
    }

    private func playlistRecord(
        for entry: LibraryDirectoryEntry,
        knownPaths: Set<String>
    ) throws -> QobuzLibraryCollectionRecord? {
        guard entry.metadata.kind == .regularFile,
              let filename = entry.path.lastComponent,
              QobuzManagedLibraryAssetPolicy.playlistExtensions.contains(
                  (filename as NSString).pathExtension.lowercased()
              ) else { return nil }
        let contents = try fileSystem.readString(
            entry.path,
            maximumBytes: LibraryArtifactLimits.playlist
        )
        let folderPath = entry.path.parent
        let folderURL = fileSystem.displayURL(for: folderPath)
        let trackPaths = QobuzM3UPlaylist.resolvedRelativePaths(
            in: contents,
            playlistFolder: folderURL,
            libraryRoot: fileSystem.rootURL
        ).filter(knownPaths.contains)
        guard !trackPaths.isEmpty else { return nil }

        let parsed = playlistIdentity(folderPath.lastComponent ?? "Playlist")
        let description = try description(in: folderPath)
        return QobuzLibraryRecordFactory.playlist(
            qobuzID: parsed.id ?? folderPath.rawValue,
            title: parsed.title.isEmpty ? (filename as NSString).deletingPathExtension : parsed.title,
            owner: nil,
            relativePath: folderPath.rawValue,
            trackPaths: trackPaths,
            artworkRelativePath: try artwork(in: folderPath),
            description: description,
            sourceTrackCount: trackPaths.count
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

    private func description(in folder: LibraryRelativePath) throws -> String? {
        let path = try folder.appending(QobuzManagedLibraryAssetPolicy.descriptionFilename)
        guard let metadata = try fileSystem.metadata(at: path),
              metadata.kind == .regularFile else { return nil }
        let value = try fileSystem.readString(
            path,
            maximumBytes: LibraryArtifactLimits.description
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func artwork(in folder: LibraryRelativePath) throws -> String? {
        for filename in EmbeddedArtwork.externalFilenames {
            let path = try folder.appending(filename)
            guard let metadata = try fileSystem.metadata(at: path),
                  metadata.kind == .regularFile else { continue }
            return path.rawValue
        }
        return nil
    }
}
