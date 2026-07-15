import Foundation

struct QobuzCollectionSidecarWriter: @unchecked Sendable {
    private let fetcher: any QobuzAssetFetching
    private let fileManager: FileManager
    private let atomicWriter: QobuzAtomicFileWriter

    init(fetcher: any QobuzAssetFetching, fileManager: FileManager, atomicWriter: QobuzAtomicFileWriter) {
        self.fetcher = fetcher
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
    }

    func downloadBooklets(for outputs: [(item: QobuzResolvedTrack, audioURL: URL)]) async throws -> [URL] {
        var visited = Set<QobuzID>()
        var created: [URL] = []
        for output in outputs where output.item.collection.usesAlbumFolders {
            try Task.checkCancellation()
            let album = output.item.album
            guard visited.insert(album.id).inserted, let source = album.bookletURL else { continue }
            let destination = output.audioURL.deletingLastPathComponent().appendingPathComponent("Booklet.pdf")
            if fileManager.fileExists(atPath: destination.path) {
                created.append(destination)
                continue
            }
            let response = try await fetcher.fetch(source)
            guard response.data.starts(with: Data("%PDF-".utf8)) else {
                throw NativeQobuzError.invalidResponse("Qobuz booklet is not a PDF")
            }
            try atomicWriter.write(response.data, to: destination)
            created.append(destination)
        }
        return created
    }

    func writeAlbumDescriptions(for outputs: [(item: QobuzResolvedTrack, audioURL: URL)]) throws -> [URL] {
        var visited = Set<QobuzID>()
        var created: [URL] = []
        for output in outputs where output.item.collection.writesAlbumCollectionAssets {
            let album = output.item.album
            guard visited.insert(album.id).inserted,
                  let description = album.albumDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else { continue }
            let destination = output.audioURL.deletingLastPathComponent().appendingPathComponent("description.txt")
            try atomicWriter.write(Data(description.utf8), to: destination)
            created.append(destination)
        }
        return created
    }
}
