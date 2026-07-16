import Foundation

struct QobuzArtworkAssets: @unchecked Sendable {
    private let fetcher: any QobuzAssetFetching

    init(fetcher: any QobuzAssetFetching) {
        self.fetcher = fetcher
    }

    func artwork(for album: QobuzAlbum) async throws -> EmbeddedArtwork? {
        guard let url = album.originalArtworkURL else { return nil }
        let response = try await fetcher.fetch(url)
        return try EmbeddedArtwork.validated(data: response.data, mimeType: response.mimeType)
    }

    func saveExternalArtwork(
        _ artwork: EmbeddedArtwork,
        for item: QobuzResolvedTrack,
        audioURL: URL,
        fileSystem: LibraryFileSystem
    ) throws -> URL? {
        guard item.collection.usesAlbumFolders else { return nil }
        let folder = try fileSystem.relativePath(for: audioURL).parent
        for filename in EmbeddedArtwork.externalFilenames {
            let candidate = try folder.appending(filename)
            if try fileSystem.metadata(at: candidate)?.kind == .regularFile {
                return fileSystem.displayURL(for: candidate)
            }
        }
        let destination = try folder.appending(artwork.externalFilename)
        try fileSystem.writeAtomically(artwork.data, to: destination)
        return fileSystem.displayURL(for: destination)
    }
}
