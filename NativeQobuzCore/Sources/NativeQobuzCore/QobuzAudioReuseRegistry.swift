import Foundation

final class QobuzAudioReuseRegistry: @unchecked Sendable {
    private let assetWriter: QobuzCollectionAssetWriter
    private let index: QobuzReusableAudioIndex

    init(assetWriter: QobuzCollectionAssetWriter, index: QobuzReusableAudioIndex) {
        self.assetWriter = assetWriter
        self.index = index
    }

    func load(root: URL) -> [String: URL] {
        do {
            let values = try index.values(for: root) {
                try assetWriter.reusableAudioIndex(root: root)
            }
            qobuzLog.debug(
                "download.reuse",
                "Reusable audio index loaded",
                metadata: ["candidateCount": String(values.count)]
            )
            return values
        } catch {
            qobuzLog.warning(
                "download.reuse",
                "Reusable audio index could not be loaded; continuing without reuse",
                error: error
            )
            return [:]
        }
    }

    func store(_ destination: URL, reuseKey: String, root: URL) {
        index.store(destination, reuseKey: reuseKey, root: root)
    }
}
