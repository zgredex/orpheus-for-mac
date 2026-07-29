import Foundation

struct QobuzArchiveManifestDiscovery {
    func manifestPaths(in fileSystem: LibraryFileSystem) throws -> (paths: [LibraryRelativePath], issues: [QobuzArchiveIssue]) {
        let snapshot = try fileSystem.recursiveSnapshot()
        let issues = snapshot.issues.map {
            QobuzArchiveIssue(relativePath: $0.path.rawValue, message: $0.message)
        }
        let paths = snapshot.entries.compactMap { entry -> LibraryRelativePath? in
            guard entry.path.lastComponent == QobuzProvenanceManifestIO.filename else { return nil }
            guard entry.metadata.kind == .regularFile else { return nil }
            return entry.path
        }
        return (paths, issues)
    }

    func playlistManifestReferencesFiles(
        in folder: LibraryRelativePath,
        filenames: Set<String>,
        fileSystem: LibraryFileSystem
    ) -> Bool {
        guard let contents = try? fileSystem.entries(in: folder) else { return false }
        for entry in contents where entry.metadata.kind == .regularFile {
            let ext = (entry.path.lastComponent! as NSString).pathExtension.lowercased()
            guard QobuzManagedLibraryAssetPolicy.playlistExtensions.contains(ext),
                  let text = try? fileSystem.readString(
                      entry.path,
                      maximumBytes: LibraryArtifactLimits.playlist
                  ) else { continue }
            if QobuzM3UPlaylist.referencesAnyLeafName(in: text, names: filenames) { return true }
        }
        return false
    }

    func resolvedArchiveKind(
        _ recordedKind: QobuzArchiveKind,
        relativePath: String,
        hasPlaylistManifest: Bool
    ) -> QobuzArchiveKind {
        guard recordedKind == .unclassified else { return recordedKind }
        let components = relativePath.split(separator: "/")
        if components.count >= 3 { return .album }
        if components.count == 2 { return hasPlaylistManifest ? .playlist : .track }
        return .unclassified
    }
}
