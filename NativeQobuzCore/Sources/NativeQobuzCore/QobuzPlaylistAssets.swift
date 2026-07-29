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

    init(
        fetcher: any QobuzAssetFetching,
        outputPlanner: any QobuzOutputPlanning,
        folderPlanner: QobuzPlaylistFolderPlanner
    ) {
        self.fetcher = fetcher
        self.outputPlanner = outputPlanner
        self.folderPlanner = folderPlanner
    }

    func writePlaylist(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> URL? {
        guard case .playlist(let id) = plan.request, !outputs.isEmpty else { return nil }
        let folder = folderPlanner.folder(title: plan.title, id: id, root: fileSystem.rootURL)
        let folderPath = try fileSystem.relativePath(for: folder)
        let destination = try folderPath.appending("\(outputPlanner.sanitize(plan.title)).m3u")
        var lines = ["#EXTM3U"]
        for output in outputs {
            let duration = output.item.track.duration ?? -1
            let artist = output.item.track.performer?.name ?? output.item.album.artist.name
            lines.append("#EXTINF:\(duration), \(artist) - \(output.item.track.displayTitle)")
            lines.append(try portableRelativePath(from: folderPath, to: output.audioURL, fileSystem: fileSystem))
            lines.append("")
        }
        try fileSystem.writeAtomically(Data(lines.joined(separator: "\n").utf8), to: destination)
        return fileSystem.displayURL(for: destination)
    }

    func writeMetadata(plan: QobuzDownloadPlan, fileSystem: LibraryFileSystem) async throws -> [URL] {
        guard case .playlist(let id) = plan.request,
              case .playlist(let playlist)? = plan.source else { return [] }
        let folder = folderPlanner.folder(title: plan.title, id: id, root: fileSystem.rootURL)
        let folderPath = try fileSystem.relativePath(for: folder)
        var created: [URL] = []
        if let description = playlist.playlistDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            let destination = try folderPath.appending("description.txt")
            try fileSystem.writeAtomically(Data(description.utf8), to: destination)
            created.append(fileSystem.displayURL(for: destination))
        }
        if let source = playlist.artworkURL {
            if let existing = try existingArtwork(in: folderPath, fileSystem: fileSystem) {
                created.append(fileSystem.displayURL(for: existing))
            } else {
                let response = try await fetcher.fetch(
                    source,
                    maximumBytes: QobuzNetworkLimits.artwork
                )
                let artwork = try EmbeddedArtwork.validated(data: response.data, mimeType: response.mimeType)
                let destination = try folderPath.appending(artwork.externalFilename)
                try fileSystem.writeAtomically(artwork.data, to: destination)
                created.append(fileSystem.displayURL(for: destination))
            }
        }
        return created
    }

    private func portableRelativePath(
        from folder: LibraryRelativePath,
        to target: URL,
        fileSystem: LibraryFileSystem
    ) throws -> String {
        let folderParts = folder.components
        let targetParts = try fileSystem.relativePath(for: target).components
        var shared = 0
        while shared < folderParts.count,
              shared < targetParts.count,
              folderParts[shared] == targetParts[shared] { shared += 1 }
        let parents = Array(repeating: "..", count: folderParts.count - shared)
        return (parents + Array(targetParts.dropFirst(shared))).joined(separator: "/")
    }

    private func existingArtwork(
        in folder: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) throws -> LibraryRelativePath? {
        for filename in EmbeddedArtwork.externalFilenames {
            let path = try folder.appending(filename)
            if try fileSystem.metadata(at: path)?.kind == .regularFile { return path }
        }
        return nil
    }
}
