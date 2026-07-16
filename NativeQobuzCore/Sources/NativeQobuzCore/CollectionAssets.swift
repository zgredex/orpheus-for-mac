import Foundation

/// Stable public facade for collection assets. Each operation delegates to the
/// component that exclusively owns that asset type.
public struct QobuzCollectionAssetWriter: @unchecked Sendable {
    private let artworkAssets: QobuzArtworkAssets
    private let sidecarWriter: QobuzCollectionSidecarWriter
    private let playlistAssets: QobuzPlaylistAssets
    private let libraryWriter: QobuzLibraryCollectionWriter
    private let provenanceStore: QobuzProvenanceStore

    public init(
        fetcher: any QobuzAssetFetching = URLSessionQobuzAssetFetcher(),
        outputPlanner: any QobuzOutputPlanning = StandardQobuzOutputPlanner()
    ) {
        let folderPlanner = QobuzPlaylistFolderPlanner(outputPlanner: outputPlanner)
        artworkAssets = QobuzArtworkAssets(fetcher: fetcher)
        sidecarWriter = QobuzCollectionSidecarWriter(fetcher: fetcher)
        playlistAssets = QobuzPlaylistAssets(
            fetcher: fetcher,
            outputPlanner: outputPlanner,
            folderPlanner: folderPlanner
        )
        libraryWriter = QobuzLibraryCollectionWriter(folderPlanner: folderPlanner)
        provenanceStore = QobuzProvenanceStore()
    }

    public func artwork(for album: QobuzAlbum) async throws -> EmbeddedArtwork? {
        try await artworkAssets.artwork(for: album)
    }

    public func saveExternalArtwork(
        _ artwork: EmbeddedArtwork,
        for item: QobuzResolvedTrack,
        audioURL: URL,
        fileSystem: LibraryFileSystem
    ) throws -> URL? {
        try artworkAssets.saveExternalArtwork(artwork, for: item, audioURL: audioURL, fileSystem: fileSystem)
    }

    public func downloadBooklets(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) async throws -> [URL] {
        try await sidecarWriter.downloadBooklets(for: outputs, fileSystem: fileSystem)
    }

    public func writeAlbumDescriptions(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> [URL] {
        try sidecarWriter.writeAlbumDescriptions(for: outputs, fileSystem: fileSystem)
    }

    public func writePlaylist(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> URL? {
        try playlistAssets.writePlaylist(plan: plan, outputs: outputs, fileSystem: fileSystem)
    }

    public func writePlaylistMetadata(plan: QobuzDownloadPlan, fileSystem: LibraryFileSystem) async throws -> [URL] {
        try await playlistAssets.writeMetadata(plan: plan, fileSystem: fileSystem)
    }

    public func recordLibraryCollections(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> URL {
        try libraryWriter.record(plan: plan, outputs: outputs, fileSystem: fileSystem)
    }

    public func reusableAudioIndex(fileSystem: LibraryFileSystem) throws -> [String: URL] {
        try provenanceStore.reusableAudioIndex(fileSystem: fileSystem)
    }

    public func writeChecksumManifests(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)],
        fileSystem: LibraryFileSystem
    ) throws -> [URL] {
        try provenanceStore.writeChecksumManifests(for: outputs, fileSystem: fileSystem)
    }

    public func expectedChecksum(for audioURL: URL, fileSystem: LibraryFileSystem) throws -> String? {
        try provenanceStore.expectedChecksum(for: audioURL, fileSystem: fileSystem)
    }

    public func provenance(for audioURL: URL, fileSystem: LibraryFileSystem) throws -> QobuzFileProvenance? {
        try provenanceStore.provenance(for: audioURL, fileSystem: fileSystem)
    }

    public func recordProvenance(
        _ provenance: QobuzFileProvenance,
        for audioURL: URL,
        fileSystem: LibraryFileSystem
    ) throws {
        try provenanceStore.record(provenance, for: audioURL, fileSystem: fileSystem)
    }

    public func markLibraryManaged(_ audioURLs: [URL], fileSystem: LibraryFileSystem) throws {
        try provenanceStore.markLibraryManaged(audioURLs, fileSystem: fileSystem)
    }
}
