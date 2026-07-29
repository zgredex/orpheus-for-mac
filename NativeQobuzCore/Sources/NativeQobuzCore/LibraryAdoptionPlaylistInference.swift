import Foundation

struct QobuzLibraryPlaylistInference {
    let fileSystem: LibraryFileSystem

    func infer(snapshot: QobuzArchiveSnapshot) -> [QobuzLibraryCollectionRecord] {
        let knownPaths = Set(snapshot.tracks.map(\.relativePath))
        guard let entries = try? fileSystem.recursiveSnapshot().entries else { return [] }
        return entries.compactMap { playlistRecord(for: $0, knownPaths: knownPaths) }
            .sorted { $0.id < $1.id }
    }

    private func playlistRecord(
        for entry: LibraryDirectoryEntry,
        knownPaths: Set<String>
    ) -> QobuzLibraryCollectionRecord? {
        guard entry.metadata.kind == .regularFile,
              let filename = entry.path.lastComponent,
              ["m3u", "m3u8"].contains((filename as NSString).pathExtension.lowercased()),
              let contents = try? fileSystem.readString(
                  entry.path,
                  maximumBytes: LibraryArtifactLimits.playlist
              ) else { return nil }
        let folderPath = entry.path.parent
        let folderURL = fileSystem.displayURL(for: folderPath)
        let trackPaths = QobuzM3UPlaylist.resolvedRelativePaths(
            in: contents,
            playlistFolder: folderURL,
            libraryRoot: fileSystem.rootURL
        ).filter(knownPaths.contains)
        guard !trackPaths.isEmpty else { return nil }

        let parsed = playlistIdentity(folderPath.lastComponent ?? "Playlist")
        let description = description(in: folderPath)
        return QobuzLibraryRecordFactory.playlist(
            qobuzID: parsed.id ?? folderPath.rawValue,
            title: parsed.title.isEmpty ? (filename as NSString).deletingPathExtension : parsed.title,
            owner: nil,
            relativePath: folderPath.rawValue,
            trackPaths: trackPaths,
            artworkRelativePath: artwork(in: folderPath),
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

    private func description(in folder: LibraryRelativePath) -> String? {
        guard let path = try? folder.appending("description.txt"),
              let metadata = try? fileSystem.metadata(at: path),
              metadata.kind == .regularFile,
              let value = try? fileSystem.readString(
                  path,
                  maximumBytes: LibraryArtifactLimits.description
              ) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func artwork(in folder: LibraryRelativePath) -> String? {
        for filename in EmbeddedArtwork.externalFilenames {
            guard let path = try? folder.appending(filename),
                  let metadata = try? fileSystem.metadata(at: path),
                  metadata.kind == .regularFile else { continue }
            return path.rawValue
        }
        return nil
    }
}
