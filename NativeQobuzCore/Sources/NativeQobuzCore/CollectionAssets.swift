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
        outputPlanner: any QobuzOutputPlanning = StandardQobuzOutputPlanner(),
        fileManager: FileManager = .default
    ) {
        let atomicWriter = QobuzAtomicFileWriter(fileManager: fileManager)
        let folderPlanner = QobuzPlaylistFolderPlanner(outputPlanner: outputPlanner)
        artworkAssets = QobuzArtworkAssets(
            fetcher: fetcher,
            fileManager: fileManager,
            atomicWriter: atomicWriter
        )
        sidecarWriter = QobuzCollectionSidecarWriter(
            fetcher: fetcher,
            fileManager: fileManager,
            atomicWriter: atomicWriter
        )
        playlistAssets = QobuzPlaylistAssets(
            fetcher: fetcher,
            outputPlanner: outputPlanner,
            folderPlanner: folderPlanner,
            fileManager: fileManager,
            atomicWriter: atomicWriter
        )
        libraryWriter = QobuzLibraryCollectionWriter(
            folderPlanner: folderPlanner,
            fileManager: fileManager
        )
        provenanceStore = QobuzProvenanceStore(
            fileManager: fileManager,
            atomicWriter: atomicWriter
        )
    }

    public func artwork(for album: QobuzAlbum) async throws -> EmbeddedArtwork? {
        try await artworkAssets.artwork(for: album)
    }

    public func saveExternalArtwork(
        _ artwork: EmbeddedArtwork,
        for item: QobuzResolvedTrack,
        audioURL: URL
    ) throws -> URL? {
        try artworkAssets.saveExternalArtwork(artwork, for: item, audioURL: audioURL)
    }

    public func downloadBooklets(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)]
    ) async throws -> [URL] {
        try await sidecarWriter.downloadBooklets(for: outputs)
    }

    public func writeAlbumDescriptions(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)]
    ) throws -> [URL] {
        try sidecarWriter.writeAlbumDescriptions(for: outputs)
    }

    public func writePlaylist(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        downloadRoot: URL
    ) throws -> URL? {
        try playlistAssets.writePlaylist(plan: plan, outputs: outputs, downloadRoot: downloadRoot)
    }

    public func writePlaylistMetadata(plan: QobuzDownloadPlan, downloadRoot: URL) async throws -> [URL] {
        try await playlistAssets.writeMetadata(plan: plan, downloadRoot: downloadRoot)
    }

    public func recordLibraryCollections(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        downloadRoot: URL
    ) throws -> URL {
        try libraryWriter.record(plan: plan, outputs: outputs, downloadRoot: downloadRoot)
    }

    public func reusableAudioIndex(root: URL) throws -> [String: URL] {
        try provenanceStore.reusableAudioIndex(root: root)
    }

    public func writeChecksumManifests(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)]
    ) throws -> [URL] {
        try provenanceStore.writeChecksumManifests(for: outputs)
    }

    public func expectedChecksum(for audioURL: URL) throws -> String? {
        try provenanceStore.expectedChecksum(for: audioURL)
    }

    public func provenance(for audioURL: URL) throws -> QobuzFileProvenance? {
        try provenanceStore.provenance(for: audioURL)
    }

    public func recordProvenance(_ provenance: QobuzFileProvenance, for audioURL: URL) throws {
        try provenanceStore.record(provenance, for: audioURL)
    }

    public func markLibraryManaged(_ audioURLs: [URL]) throws {
        try provenanceStore.markLibraryManaged(audioURLs)
    }
}
