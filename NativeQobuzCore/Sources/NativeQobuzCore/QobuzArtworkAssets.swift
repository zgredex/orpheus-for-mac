import Foundation

struct QobuzArtworkAssets: @unchecked Sendable {
    private let fetcher: any QobuzAssetFetching
    private let fileManager: FileManager
    private let atomicWriter: QobuzAtomicFileWriter

    init(fetcher: any QobuzAssetFetching, fileManager: FileManager, atomicWriter: QobuzAtomicFileWriter) {
        self.fetcher = fetcher
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
    }

    func artwork(for album: QobuzAlbum) async throws -> EmbeddedArtwork? {
        guard let url = album.originalArtworkURL else { return nil }
        let response = try await fetcher.fetch(url)
        return try EmbeddedArtwork.validated(data: response.data, mimeType: response.mimeType)
    }

    func saveExternalArtwork(
        _ artwork: EmbeddedArtwork,
        for item: QobuzResolvedTrack,
        audioURL: URL
    ) throws -> URL? {
        guard item.collection.usesAlbumFolders else { return nil }
        let folder = audioURL.deletingLastPathComponent()
        if let existing = EmbeddedArtwork.existingExternalFile(in: folder, fileManager: fileManager) {
            return existing
        }
        let destination = folder.appendingPathComponent(artwork.externalFilename)
        if fileManager.fileExists(atPath: destination.path) { return destination }
        try atomicWriter.write(artwork.data, to: destination)
        return destination
    }
}
