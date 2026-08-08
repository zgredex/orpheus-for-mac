import AppKit
import Foundation
import NativeQobuzCore

@MainActor
final class NativeLibraryController: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var snapshot: QobuzArchiveSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var isPerformingAdoption = false
    private let archiveStore: any NativeArchiveIndexStoring
    private let scanner: any QobuzArchiveScanning
    private let adoption: NativeLibraryAdoptionTransactionController
    private let cacheRestorer: NativeLibraryCacheRestorer
    private let downloadedIndexer: NativeDownloadedLibraryIndexer
    private let revealer = NativeLibraryRevealController()
    private let statusResolver = NativeLibraryStatusResolver()
    private var cacheLoadTask: Task<Void, Never>?
    private var cacheGeneration: UInt64 = 0
    private var activeRootPath: String?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    init(
        archiveStore: any NativeArchiveIndexStoring,
        scanner: any QobuzArchiveScanning,
        adopter: any QobuzLibraryAdopting
    ) {
        self.archiveStore = archiveStore
        self.scanner = scanner
        adoption = NativeLibraryAdoptionTransactionController(
            archiveStore: archiveStore,
            adopter: adopter
        )
        cacheRestorer = NativeLibraryCacheRestorer(archiveStore: archiveStore)
        downloadedIndexer = NativeDownloadedLibraryIndexer(
            archiveStore: archiveStore,
            scanner: scanner
        )
    }

    @discardableResult
    func loadCache(for root: URL) async -> NativeLibraryCacheLoadStatus {
        let standardizedRoot = root.standardizedFileURL
        let generation = cacheGeneration
        let restoration = await cacheRestorer.restore(for: standardizedRoot)
        guard !Task.isCancelled, generation == cacheGeneration else {
            return restoration.status
        }
        guard activeRootPath == nil || activeRootPath == standardizedRoot.path else {
            qobuzLog.debug(
                "library.cache",
                "Superseded archive cache restoration was discarded",
                metadata: [
                    "cachedRoot": standardizedRoot.path,
                    "activeRoot": activeRootPath ?? "none"
                ]
            )
            return restoration.status
        }
        snapshot = restoration.snapshot
        return restoration.status
    }
    func open(root: URL, onFailure: @escaping @MainActor (String) -> Void) {
        let standardizedRoot = root.standardizedFileURL
        activeRootPath = standardizedRoot.path
        if snapshot?.rootPath != standardizedRoot.path {
            snapshot = nil
        }
        isOpen = true
        qobuzLog.notice("library.ui", "Library opened", metadata: ["downloadRoot": standardizedRoot.path])
        if snapshot == nil {
            cancelCacheLoad()
            let generation = cacheGeneration
            isScanning = true
            cacheLoadTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if cacheGeneration == generation { cacheLoadTask = nil }
                }
                _ = await loadCache(for: standardizedRoot)
                guard !Task.isCancelled, cacheGeneration == generation, isOpen else { return }
                cacheLoadTask = nil
                refresh(root: standardizedRoot, onFailure: onFailure)
            }
        } else {
            refresh(root: standardizedRoot, onFailure: onFailure)
        }
    }

    func close() {
        cancelRefresh()
        isOpen = false
        qobuzLog.debug("library.ui", "Library closed")
    }

    func invalidate() {
        cancelRefresh()
        activeRootPath = nil
        snapshot = nil
    }

    func cancelRefresh() {
        cancelCacheLoad()
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isScanning = false
    }

    private func cancelCacheLoad() {
        cacheGeneration &+= 1
        cacheLoadTask?.cancel()
        cacheLoadTask = nil
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
                    try await Task.detached(priority: .userInitiated) {
                        try QobuzLibraryMutationRecovery.recover(at: standardizedRoot)
                    }.value
                    return try await self.scanner.scan(root: standardizedRoot, reusing: reusableSnapshot)
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

    func indexDownloadedRoot(
        _ root: URL,
        changedAudioURLs: [URL],
        activeRoot: URL
    ) async throws {
        cancelRefresh()
        isScanning = true
        defer { isScanning = false }
        let standardizedRoot = root.standardizedFileURL
        let reusable = snapshot?.rootPath == standardizedRoot.path ? snapshot : nil
        do {
            let indexed = try await downloadedIndexer.index(
                root: standardizedRoot,
                reusing: reusable,
                changedAudioURLs: changedAudioURLs
            )
            if standardizedRoot == activeRoot.standardizedFileURL { snapshot = indexed }
        } catch {
            qobuzLog.error(
                "download.library.index",
                "Downloaded output could not be committed to the Library index",
                metadata: [
                    "downloadRoot": standardizedRoot.path,
                    "changedAudioCount": String(changedAudioURLs.count)
                ],
                error: error
            )
            throw error
        }
    }

    func inspectForAdoption(at root: URL, downloadIsActive: Bool) async throws -> QobuzLibraryAdoptionPlan {
        let (_, plan) = try await performAdoptionOperation(
            at: root,
            downloadIsActive: downloadIsActive,
            requestedMessage: "Library adoption inspection requested",
            failureMessage: "Library adoption inspection failed"
        ) {
            try await adoption.inspect(root: root)
        }
        return plan
    }

    func prepareAdoption(at root: URL, downloadIsActive: Bool) async throws -> NativePendingLibraryAdoption {
        let (adoptionID, prepared) = try await performAdoptionOperation(
            at: root,
            downloadIsActive: downloadIsActive,
            requestedMessage: "Library adoption confirmed",
            failureMessage: "Library adoption failed"
        ) {
            try await adoption.prepare(root: root)
        }
        return NativePendingLibraryAdoption(id: adoptionID, prepared: prepared)
    }

    private func performAdoptionOperation<Value>(
        at root: URL,
        downloadIsActive: Bool,
        requestedMessage: String,
        failureMessage: String,
        operation: () async throws -> Value
    ) async throws -> (id: String, value: Value) {
        guard !downloadIsActive else {
            throw NativeQobuzError.unavailable("A Library cannot be adopted during an active download.")
        }
        guard !isScanning, !isPerformingAdoption else {
            throw NativeQobuzError.unavailable("Another Library operation is already running.")
        }
        isPerformingAdoption = true
        defer { isPerformingAdoption = false }
        let adoptionID = UUID().uuidString
        qobuzLog.notice(
            "library.adoption.ui",
            requestedMessage,
            metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path]
        )
        do {
            let result = try await QobuzLogScope.withValue(["libraryAdoptionID": adoptionID]) {
                try await operation()
            }
            return (adoptionID, result)
        } catch {
            qobuzLog.error(
                "library.adoption.ui",
                failureMessage,
                metadata: ["libraryAdoptionID": adoptionID, "candidateRoot": root.path],
                error: error
            )
            throw error
        }
    }

    func stageActivation(_ pending: NativePendingLibraryAdoption) throws -> NativeStagedLibraryAdoption {
        try adoption.stageActivation(pending)
    }

    func prepareActivationCommit(_ staged: NativeStagedLibraryAdoption) throws {
        try adoption.prepareActivationCommit(staged)
    }

    func finishActivationCommit(_ staged: NativeStagedLibraryAdoption) throws {
        try adoption.finishActivationCommit(staged)
    }

    func rollbackActivation(_ staged: NativeStagedLibraryAdoption, primaryError: Error) throws -> Never {
        try adoption.rollbackActivation(staged, primaryError: primaryError)
    }

    func publishActivation(_ staged: NativeStagedLibraryAdoption) {
        let pending = staged.pending
        cancelRefresh()
        activeRootPath = pending.result.plan.root.path
        snapshot = pending.result.snapshot
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

    func install(_ value: QobuzArchiveSnapshot, open: Bool = true) throws {
        cancelRefresh()
        try archiveStore.save(value)
        snapshot = value
        isOpen = open
    }

    func revealTrack(_ track: QobuzArchiveTrack) {
        revealer.reveal(relativePath: track.relativePath, snapshot: snapshot)
    }

    func revealEntry(_ entry: QobuzArchiveEntry) {
        revealer.reveal(relativePath: entry.relativePath, snapshot: snapshot)
    }

    func revealIssue(_ issue: NativeLibraryIndexProblem) {
        revealer.reveal(relativePath: issue.relativePath, snapshot: snapshot, allowingRoot: true)
    }

    func status(for item: NativeQueueItem) -> NativeLibraryStatus? {
        statusResolver.status(for: item, snapshot: snapshot)
    }

    func status(for album: QobuzAlbumSummary) -> NativeLibraryStatus? {
        statusResolver.status(for: album, snapshot: snapshot)
    }

    func status(for album: QobuzAlbum) -> NativeLibraryStatus? {
        statusResolver.status(for: album, snapshot: snapshot)
    }

    func status(for track: QobuzTrack) -> NativeLibraryStatus? {
        statusResolver.status(for: track, snapshot: snapshot)
    }

    func status(for tracks: [QobuzTrack]) -> NativeLibraryStatus? {
        statusResolver.status(for: tracks, snapshot: snapshot)
    }

}
