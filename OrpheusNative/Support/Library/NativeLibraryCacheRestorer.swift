import Foundation
import NativeQobuzCore

enum NativeLibraryCacheLoadStatus: Equatable, Sendable {
    case restored
    case missing
    case rejected
}

struct NativeLibraryCacheRestoration: Sendable {
    let status: NativeLibraryCacheLoadStatus
    let snapshot: QobuzArchiveSnapshot?
}

struct NativeLibraryCacheRestorer: Sendable {
    private let archiveStore: any NativeArchiveIndexStoring

    init(archiveStore: any NativeArchiveIndexStoring) {
        self.archiveStore = archiveStore
    }

    func restore(for root: URL) async -> NativeLibraryCacheRestoration {
        let rootPath = root.standardizedFileURL.path
        do {
            let archiveStore = archiveStore
            let result = try await Task.detached(priority: .userInitiated) {
                try archiveStore.load()
            }.value
            switch result {
            case .restored(let cached) where cached.rootPath == rootPath:
                qobuzLog.debug(
                    "library.cache",
                    "Archive cache restored",
                    metadata: [
                        "trackCount": String(cached.tracks.count),
                        "problemCount": String(cached.problemCount)
                    ]
                )
                return NativeLibraryCacheRestoration(status: .restored, snapshot: cached)
            case .restored:
                qobuzLog.debug("library.cache", "Archive cache did not match the current download root")
                return NativeLibraryCacheRestoration(status: .missing, snapshot: nil)
            case .missing:
                return NativeLibraryCacheRestoration(status: .missing, snapshot: nil)
            case .rejected:
                return NativeLibraryCacheRestoration(status: .rejected, snapshot: nil)
            }
        } catch {
            qobuzLog.warning("library.cache", "Archive cache could not be restored", error: error)
            return NativeLibraryCacheRestoration(status: .missing, snapshot: nil)
        }
    }
}
