import Foundation

struct QobuzArchiveManifestDiscovery {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func manifestURLs(in root: URL) throws -> (urls: [URL], issues: [QobuzArchiveIssue]) {
        var issues: [QobuzArchiveIssue] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                qobuzLog.warning(
                    "library.scan.enumeration",
                    "Download folder enumeration encountered an error",
                    metadata: ["path": url.path],
                    error: error
                )
                issues.append(QobuzArchiveIssue(
                    relativePath: QobuzPathSafety.relativePathOrLastComponent(
                        of: url,
                        in: root,
                        allowingRoot: true
                    ),
                    message: error.localizedDescription
                ))
                return true
            }
        ) else {
            throw NativeQobuzError.fileSystem("Could not enumerate the download folder.")
        }
        var urls: [URL] = []
        while let value = enumerator.nextObject() as? URL {
            if value.lastPathComponent == QobuzProvenanceManifestIO.filename { urls.append(value) }
        }
        return (urls, issues)
    }

    func playlistManifestReferencesFiles(in folder: URL, filenames: Set<String>) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for url in contents where ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
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
