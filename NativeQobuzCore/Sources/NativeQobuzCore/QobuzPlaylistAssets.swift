import Foundation

struct QobuzPlaylistFolderPlanner: Sendable {
    private let outputPlanner: any QobuzOutputPlanning

    init(outputPlanner: any QobuzOutputPlanning) {
        self.outputPlanner = outputPlanner
    }

    func folder(title: String, id: QobuzID, root: URL) -> URL {
        root
            .appendingPathComponent("Playlists", isDirectory: true)
            .appendingPathComponent(
                QobuzFilenameComponent.make(
                    stem: outputPlanner.sanitize(title),
                    suffix: " [\(QobuzFilenameComponent.truncate(outputPlanner.sanitize(id.rawValue), toUTF8Bytes: 64))]"
                ),
                isDirectory: true
            )
    }
}

struct QobuzPlaylistAssets: @unchecked Sendable {
    private let fetcher: any QobuzAssetFetching
    private let outputPlanner: any QobuzOutputPlanning
    private let folderPlanner: QobuzPlaylistFolderPlanner
    private let fileManager: FileManager
    private let atomicWriter: QobuzAtomicFileWriter

    init(
        fetcher: any QobuzAssetFetching,
        outputPlanner: any QobuzOutputPlanning,
        folderPlanner: QobuzPlaylistFolderPlanner,
        fileManager: FileManager,
        atomicWriter: QobuzAtomicFileWriter
    ) {
        self.fetcher = fetcher
        self.outputPlanner = outputPlanner
        self.folderPlanner = folderPlanner
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
    }

    func writePlaylist(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        downloadRoot: URL
    ) throws -> URL? {
        guard case .playlist(let id) = plan.request, !outputs.isEmpty else { return nil }
        let folder = folderPlanner.folder(title: plan.title, id: id, root: downloadRoot)
        let destination = folder.appendingPathComponent("\(outputPlanner.sanitize(plan.title)).m3u")
        var lines = ["#EXTM3U"]
        for output in outputs {
            let duration = output.item.track.duration ?? -1
            let artist = output.item.track.performer?.name ?? output.item.album.artist.name
            lines.append("#EXTINF:\(duration), \(artist) - \(output.item.track.displayTitle)")
            lines.append(try portableRelativePath(from: folder, to: output.audioURL, root: downloadRoot))
            lines.append("")
        }
        try atomicWriter.write(Data(lines.joined(separator: "\n").utf8), to: destination)
        return destination
    }

    func writeMetadata(plan: QobuzDownloadPlan, downloadRoot: URL) async throws -> [URL] {
        guard case .playlist(let id) = plan.request,
              case .playlist(let playlist)? = plan.source else { return [] }
        let folder = folderPlanner.folder(title: plan.title, id: id, root: downloadRoot)
        var created: [URL] = []
        if let description = playlist.playlistDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            let destination = folder.appendingPathComponent("description.txt")
            try atomicWriter.write(Data(description.utf8), to: destination)
            created.append(destination)
        }
        if let source = playlist.artworkURL {
            if let existing = EmbeddedArtwork.existingExternalFile(in: folder, fileManager: fileManager) {
                created.append(existing)
            } else {
                let response = try await fetcher.fetch(source)
                let artwork = try EmbeddedArtwork.validated(data: response.data, mimeType: response.mimeType)
                let destination = folder.appendingPathComponent(artwork.externalFilename)
                try atomicWriter.write(artwork.data, to: destination)
                created.append(destination)
            }
        }
        return created
    }

    private func portableRelativePath(from folder: URL, to target: URL, root: URL) throws -> String {
        let folderParts = try QobuzLibraryManifestIO.relativePath(of: folder, root: root).split(separator: "/")
        let targetParts = try QobuzLibraryManifestIO.relativePath(of: target, root: root).split(separator: "/")
        var shared = 0
        while shared < folderParts.count,
              shared < targetParts.count,
              folderParts[shared] == targetParts[shared] { shared += 1 }
        let parents = Array(repeating: "..", count: folderParts.count - shared)
        return (parents + targetParts.dropFirst(shared).map(String.init)).joined(separator: "/")
    }
}
