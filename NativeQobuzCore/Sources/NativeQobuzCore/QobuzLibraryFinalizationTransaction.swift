import Foundation

struct QobuzLibraryFinalizationTransaction: @unchecked Sendable {
    private let libraryWriter: QobuzLibraryCollectionWriter
    private let playlistAssets: QobuzPlaylistAssets
    private let provenanceStore: QobuzProvenanceStore
    private let faultInjector: LibraryFileTransaction.FaultInjector

    init(
        libraryWriter: QobuzLibraryCollectionWriter,
        playlistAssets: QobuzPlaylistAssets,
        provenanceStore: QobuzProvenanceStore,
        faultInjector: @escaping LibraryFileTransaction.FaultInjector = { _ in }
    ) {
        self.libraryWriter = libraryWriter
        self.playlistAssets = playlistAssets
        self.provenanceStore = provenanceStore
        self.faultInjector = faultInjector
    }

    func commit(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) async throws -> QobuzLibraryCollectionAssets {
        let change = try libraryWriter.prepare(
            plan: plan,
            outputs: outputs,
            fileSystem: fileSystem
        )
        let manifest = try libraryWriter.manifestMutation(change, fileSystem: fileSystem)
        let playlist = try playlistAssets.playlistMutation(
            plan: plan,
            membership: change.playlistMembership,
            fileSystem: fileSystem
        )
        let audioURLs = outputs.map(\.audioURL)
        let provenance = try provenanceStore.mutationsMarkingLibraryManaged(
            audioURLs,
            fileSystem: fileSystem
        )
        let mutations = [manifest] + (playlist.map { [$0] } ?? []) + provenance
        let transaction = LibraryFileTransaction(
            fileSystem: fileSystem,
            faultInjector: faultInjector
        )
        let prepared = try await transaction.prepare(
            plan: LibraryFileTransactionPlan(
                operation: "download.library-finalization",
                mutations: mutations
            )
        ) {
            guard try QobuzLibraryManifestIO.load(in: fileSystem) == change.manifest else {
                throw NativeQobuzError.fileSystem(
                    "The prepared Library manifest did not match the authoritative collection update."
                )
            }
            try provenanceStore.validateLibraryManaged(audioURLs, fileSystem: fileSystem)
        }
        try transaction.prepareCommit(prepared.token)
        try transaction.finishCommit(prepared.token)

        return QobuzLibraryCollectionAssets(
            manifestURL: fileSystem.displayURL(for: manifest.path),
            playlistURL: playlist.map { fileSystem.displayURL(for: $0.path) }
        )
    }
}
