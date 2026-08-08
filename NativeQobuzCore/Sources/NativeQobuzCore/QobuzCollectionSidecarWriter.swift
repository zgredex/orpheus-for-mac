import Foundation

struct QobuzCollectionSidecarWriter: @unchecked Sendable {
    private let fetcher: any QobuzAssetFetching

    init(fetcher: any QobuzAssetFetching) {
        self.fetcher = fetcher
    }

    func downloadBooklets(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) async throws -> [URL] {
        var visited = Set<QobuzID>()
        var created: [URL] = []
        for output in outputs where output.item.collection.ownsAlbumFolderSidecars {
            try Task.checkCancellation()
            let album = output.item.album
            guard visited.insert(album.id).inserted, let source = album.bookletURL else { continue }
            let destination = try fileSystem.relativePath(for: output.audioURL).parent.appending(
                QobuzManagedLibraryAssetPolicy.bookletFilename
            )
            if try fileSystem.metadata(at: destination)?.kind == .regularFile {
                created.append(fileSystem.displayURL(for: destination))
                continue
            }
            let response = try await fetcher.fetch(source, maximumBytes: QobuzNetworkLimits.booklet)
            guard response.data.starts(with: Data("%PDF-".utf8)) else {
                throw NativeQobuzError.invalidResponse("Qobuz booklet is not a PDF")
            }
            try fileSystem.writeAtomically(response.data, to: destination)
            created.append(fileSystem.displayURL(for: destination))
        }
        return created
    }

    func writeAlbumDescriptions(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        fileSystem: LibraryFileSystem
    ) throws -> [URL] {
        var visited = Set<QobuzID>()
        var created: [URL] = []
        for output in outputs where output.item.collection.writesAlbumCollectionAssets {
            let album = output.item.album
            guard visited.insert(album.id).inserted,
                  let description = album.albumDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else { continue }
            let destination = try fileSystem.relativePath(for: output.audioURL).parent.appending(
                QobuzManagedLibraryAssetPolicy.descriptionFilename
            )
            try fileSystem.writeAtomically(Data(description.utf8), to: destination)
            created.append(fileSystem.displayURL(for: destination))
        }
        return created
    }
}
