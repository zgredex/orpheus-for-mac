import AppKit
import Foundation
import NativeQobuzCore

struct NativePendingLibraryAdoption {
    let id: String
    let result: QobuzLibraryAdoptionResult
}

enum NativeLibraryCacheLoadStatus: Equatable {
    case restored
    case missing
    case rejected
}

@MainActor
final class NativeLibraryController: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var snapshot: QobuzArchiveSnapshot?
    @Published private(set) var isScanning = false

    private let archiveStore: any NativeArchiveIndexStoring
    private let scanner: any QobuzArchiveScanning
    private let adopter: any QobuzLibraryAdopting
    private let downloadedIndexer: NativeDownloadedLibraryIndexer
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?

    init(
        archiveStore: any NativeArchiveIndexStoring,
        scanner: any QobuzArchiveScanning,
        adopter: any QobuzLibraryAdopting
    ) {
        self.archiveStore = archiveStore
        self.scanner = scanner
        self.adopter = adopter
        downloadedIndexer = NativeDownloadedLibraryIndexer(
            archiveStore: archiveStore,
            scanner: scanner
        )
    }

    @discardableResult
    func loadCache(for root: URL) -> NativeLibraryCacheLoadStatus {
        let rootPath = root.standardizedFileURL.path
        do {
            switch try archiveStore.load() {
            case .restored(let cached) where cached.rootPath == rootPath:
                snapshot = cached
                qobuzLog.debug(
                    "library.cache",
                    "Archive cache restored",
                    metadata: [
                        "trackCount": String(cached.tracks.count),
                        "problemCount": String(cached.problemCount)
                    ]
                )
                return .restored
            case .restored:
                snapshot = nil
                qobuzLog.debug("library.cache", "Archive cache did not match the current download root")
                return .missing
            case .missing:
                snapshot = nil
                return .missing
            case .rejected:
                snapshot = nil
                return .rejected
            }
        } catch {
            snapshot = nil
            qobuzLog.warning("library.cache", "Archive cache could not be restored", error: error)
            return .missing
        }
    }

    func open(root: URL, onFailure: @escaping @MainActor (String) -> Void) {
        isOpen = true
        qobuzLog.notice("library.ui", "Library opened", metadata: ["downloadRoot": root.path])
        if snapshot == nil { loadCache(for: root) }
        refresh(root: root, onFailure: onFailure)
    }

    func close() {
        cancelRefresh()
        isOpen = false
        qobuzLog.debug("library.ui", "Library closed")
    }

    func invalidate() {
        cancelRefresh()
        snapshot = nil
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isScanning = false
    }

    func refresh(
        root: URL,
        fullVerification: Bool = false,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        cancelRefresh()
        let standardizedRoot = root.standardizedFileURL
        let token = UUID()
        refreshID = token
        let identifier = token.uuidString
        qobuzLog.notice(
            "library.refresh",
            "Library refresh requested",
            metadata: ["libraryRefreshID": identifier, "downloadRoot": standardizedRoot.path]
        )
        isScanning = true
        let reusableSnapshot = fullVerification ? nil : snapshot
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshID == token {
                    isScanning = false
                    refreshTask = nil
                    refreshID = nil
                }
            }
            do {
                let scanned = try await QobuzLogScope.withValue(["libraryRefreshID": identifier]) {
                    try await self.scanner.scan(root: standardizedRoot, reusing: reusableSnapshot)
                }
                try Task.checkCancellation()
                guard refreshID == token else { return }
                snapshot = scanned
                try archiveStore.save(scanned)
                qobuzLog.notice(
                    "library.refresh",
                    "Library refresh applied",
                    metadata: [
                        "libraryRefreshID": identifier,
                        "trackCount": String(scanned.tracks.count),
                        "problemCount": String(scanned.problemCount)
                    ]
                )
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice(
                    "library.refresh",
                    "Library refresh cancelled",
                    metadata: ["libraryRefreshID": identifier]
                )
            } catch {
                guard refreshID == token else { return }
                qobuzLog.error(
                    "library.refresh",
                    "Library refresh failed",
                    metadata: ["libraryRefreshID": identifier],
                    error: error
                )
                onFailure("Could not scan the library: \(error.localizedDescription)")
            }
        }
    }

    func indexDownloadedRoot(_ root: URL, activeRoot: URL) async throws {
        cancelRefresh()
        isScanning = true
        defer { isScanning = false }
        let standardizedRoot = root.standardizedFileURL
        let reusable = snapshot?.rootPath == standardizedRoot.path ? snapshot : nil
        do {
            let indexed = try await downloadedIndexer.index(root: standardizedRoot, reusing: reusable)
            if standardizedRoot == activeRoot.standardizedFileURL { snapshot = indexed }
        } catch {
            qobuzLog.error(
                "download.library.index",
                "Downloaded output could not be committed to the Library index",
                metadata: ["downloadRoot": standardizedRoot.path],
                error: error
            )
            throw error
        }
    }

    func inspectForAdoption(at root: URL, downloadIsActive: Bool) async throws -> QobuzLibraryAdoptionPlan {
        guard !downloadIsActive else {
            throw NativeQobuzError.unavailable("A Library cannot be adopted during an active download.")
        }
        let adoptionID = UUID().uuidString
        qobuzLog.notice(
            "library.adoption.ui",
            "Library adoption inspection requested",
            metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        )
        do {
            return try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
                try await adopter.inspect(root: root)
            }
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                "Library adoption inspection failed",
                metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func prepareAdoption(at root: URL, downloadIsActive: Bool) async throws -> NativePendingLibraryAdoption {
        guard !downloadIsActive else {
            throw NativeQobuzError.unavailable("A Library cannot be adopted during an active download.")
        }
        let adoptionID = UUID().uuidString
        qobuzLog.notice(
            "library.adoption.ui",
            "Library adoption confirmed",
            metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        )
        do {
            let result = try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
                try await adopter.adopt(root: root)
            }
            return NativePendingLibraryAdoption(id: adoptionID, result: result)
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                "Library adoption failed",
                metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func activate(_ pending: NativePendingLibraryAdoption) throws {
        cancelRefresh()
        snapshot = pending.result.snapshot
        try archiveStore.save(pending.result.snapshot)
        isOpen = true
        qobuzLog.notice(
            "library.adoption.ui",
            "Adopted Library became the active download root",
            metadata: [
                "libraryAdoptionID": pending.id,
                "downloadRoot": pending.result.plan.root.path,
                "trackCount": String(pending.result.snapshot.tracks.count),
                "problemCount": String(pending.result.snapshot.problemCount),
                "manifestAction": pending.result.plan.manifestAction.rawValue
            ]
        )
    }

    func revealTrack(_ track: QobuzArchiveTrack) {
        reveal(relativePath: track.relativePath)
    }

    func revealEntry(_ entry: QobuzArchiveEntry) {
        reveal(relativePath: entry.relativePath)
    }

    func revealIssue(_ issue: NativeLibraryIndexProblem) {
        reveal(relativePath: issue.relativePath, allowingRoot: true)
    }

    func status(for item: NativeQueueItem) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        let coverage: QobuzArchiveCoverage
        switch item.request {
        case .track(let id):
            coverage = snapshot.coverage(trackID: id)
        case .album(let id):
            let trackIDs = item.selectedTrackIDs.map(Array.init) ?? item.expectedTrackIDs
            if let trackIDs, !trackIDs.isEmpty {
                coverage = snapshot.coverage(trackIDs: trackIDs, albumID: id)
            } else if item.selectedTrackIDs != nil {
                return nil
            } else {
                coverage = snapshot.coverage(albumID: id)
            }
        case .playlist:
            let trackIDs = item.selectedTrackIDs.map(Array.init) ?? item.expectedTrackIDs
            guard let trackIDs, !trackIDs.isEmpty else { return nil }
            coverage = snapshot.coverage(trackIDs: trackIDs)
        case .artist, .label:
            return nil
        }
        return NativeLibraryStatus(coverage)
    }

    func status(for album: QobuzAlbumSummary) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        return NativeLibraryStatus(snapshot.coverage(albumID: album.id))
    }

    func status(for album: QobuzAlbum) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        let trackIDs = album.availableTracks.map(\.id)
        let coverage = trackIDs.isEmpty
            ? snapshot.coverage(albumID: album.id)
            : snapshot.coverage(trackIDs: trackIDs, albumID: album.id)
        return NativeLibraryStatus(coverage)
    }

    func status(for track: QobuzTrack) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        return NativeLibraryStatus(snapshot.coverage(trackID: track.id, albumID: track.album?.id))
    }

    func status(for tracks: [QobuzTrack]) -> NativeLibraryStatus? {
        guard let snapshot else { return nil }
        let trackIDs = tracks.filter { $0.accountAvailabilityIssue == nil }.map(\.id)
        guard !trackIDs.isEmpty else { return nil }
        return NativeLibraryStatus(snapshot.coverage(trackIDs: trackIDs))
    }

    private func reveal(relativePath: String, allowingRoot: Bool = false) {
        guard let snapshot else { return }
        let root = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true).standardizedFileURL
        guard let target = QobuzPathSafety.containedURL(
            for: relativePath,
            in: root,
            allowingRoot: allowingRoot
        ),
        FileManager.default.fileExists(atPath: target.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
