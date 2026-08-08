import Foundation
import NativeQobuzCore
import SwiftUI
@testable import OrpheusNative

@MainActor
enum RenderedSnapshotFixtures {
    static let longAlbum = QobuzAlbum(
        id: QobuzID("album-long-copy"),
        title: "Trzydzieści — wydanie rocznicowe z niezwykle długim tytułem",
        subtitle: "Édition spéciale remasterisée",
        artist: QobuzArtist(id: QobuzID("artist-adele"), name: "Adèle Łączyńska"),
        tracks: (1...12).map { index in
            QobuzTrack(
                id: QobuzID("track-\(index)"),
                title: index == 8
                    ? "All Night Parking (with Erroll Garner) — Interlude symphonique"
                    : "Utwór numer \(index) z długim podtytułem",
                duration: 180 + index * 17,
                trackNumber: index,
                parentalWarning: index == 4,
                maximumSamplingRate: 96,
                maximumBitDepth: 24,
                maximumChannelCount: 2
            )
        },
        tracksCount: 12,
        mediaCount: 1,
        duration: 3_490,
        releaseDate: "2021-11-19",
        genre: "Pop/Rock",
        genresList: ["Pop/Rock", "Soul", "Contemporary R&B"],
        releaseType: .album,
        releaseTags: ["Anniversary Edition", "Remastered"],
        isOfficial: true,
        label: "Columbia Records International",
        albumDescription: """
        <p class="Standard">Si Adele est devenue l’une des artistes ayant vendu le plus d’albums dans l’histoire de la musique, c’est grâce à une recette bien rodée. Située entre la pop et la soul, menée par des ballades chargées d’émotion, elle crée un pont étonnant entre musique rétro et modernité. Sur <em>My Little Love</em>, elle laisse entendre des tranches de vie et des enregistrements personnels. © Brice Miclet/Qobuz</p>
        """,
        catchline: "Une production ample, intime et moderne qui conserve toute la force de sa voix.",
        copyright: "© 2021 Melted Stone under exclusive licence to Columbia Records",
        parentalWarning: true,
        maximumSamplingRate: 96,
        maximumBitDepth: 24,
        maximumChannelCount: 2,
        hiresStreamable: true
    )

    static let libraryProblems = QobuzArchiveSnapshot(
        rootPath: "/Users/example/Music/Orpheus for Mac",
        scannedAt: Date(timeIntervalSince1970: 1_720_958_400),
        tracks: [
            archiveTrack("Adèle/30/01 - Strangers By Nature.flac", formatID: 27, integrity: .missing),
            archiveTrack("Adèle/30/02 - Easy On Me.flac", formatID: 7, integrity: .checksumMismatch),
            archiveTrack("Sting/Brand New Day/03 - Desert Rose.flac", formatID: 6, integrity: .metadataConflict),
            archiveTrack("Björk/Homogenic/04 - Jóga.flac", formatID: 99, integrity: .unreadable)
        ],
        issues: [
            QobuzArchiveIssue(
                relativePath: "Björk/Homogenic/04 - Jóga.flac",
                message: "The file descriptor could not be opened because the item is a symbolic link."
            ),
            QobuzArchiveIssue(
                relativePath: "Playlists/Nocna podróż/collection.json",
                message: "The collection manifest contains a conflicting Qobuz playlist identifier."
            )
        ]
    )

    static let searchResults: [SearchResult] = [
        SearchResult(
            id: "search-1",
            artworkURL: nil,
            title: "Die außergewöhnlich lange Reise durch Klang und Erinnerung",
            subtitle: "Künstlerkollektiv für zeitgenössische Musik",
            isQueued: false,
            libraryStatus: .partial(verified: 8, total: 12, problems: 4),
            quality: .target(.hiRes),
            add: {}
        ),
        SearchResult(
            id: "search-2",
            artworkURL: nil,
            title: "Nocna podróż — wersja rozszerzona",
            subtitle: "Wielu wykonawców",
            isQueued: true,
            libraryStatus: .complete(14),
            quality: .target(.lossless),
            add: {}
        )
    ]

    static func recoveryViewModel(
        loadPreview: Bool = false
    ) async throws -> (viewModel: NativeViewModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedRecovery-\(UUID().uuidString)", isDirectory: true)
        let downloadRoot = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)

        var failedItem = NativeQueueItem(
            request: .album(QobuzID("failed-album")),
            title: "Symfonia błędów — wydanie rozszerzone"
        )
        failedItem.subtitle = "Orkiestra Diagnostyczna"
        failedItem.downloadQuality = .hiRes

        var pausedItem = NativeQueueItem(
            request: .album(QobuzID("paused-album")),
            title: "Wznowienie istniejącego pobierania"
        )
        pausedItem.subtitle = "Artysta z bardzo długą nazwą"
        pausedItem.downloadQuality = .hiRes

        let failed = try recoveryOperation(
            item: failedItem,
            status: .failed("Qobuz returned HTTP 503 after the signed URL expired."),
            root: downloadRoot,
            stem: "01 - Failed",
            phase: "Failed while validating the delivered FLAC",
            createdAt: Date(timeIntervalSince1970: 1_720_958_400),
            warnings: ["Artwork download returned HTTP 404.", "A lower available format 7 was delivered."],
            notices: ["The existing audio payload passed checksum validation."]
        )
        let paused = try recoveryOperation(
            item: pausedItem,
            status: .paused,
            root: downloadRoot,
            stem: "02 - Paused",
            phase: "Paused after app closed",
            createdAt: Date(timeIntervalSince1970: 1_720_958_401),
            warnings: [],
            notices: []
        )
        let session = NativeSessionSnapshot(
            queue: [failedItem, pausedItem],
            operations: [failed, paused],
            selectedQueueID: failedItem.id,
            linkInbox: []
        )
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
            defaultDownloadRoot: downloadRoot
        )
        let viewModel = NativeViewModel(
            paths: paths,
            configurationStore: MemoryConfigurationStore(
                paths: paths,
                credentials: loadPreview ? .complete : nil
            ),
            archiveStore: MemoryArchiveStore(),
            sessionStore: MemorySessionStore(snapshot: session),
            connectivityMonitor: FakeConnectivityMonitor(),
            powerActivityManager: FakePowerActivityManager(),
            clientFactory: { _ in FakeQobuzService() }
        )
        await viewModel.start()
        return (viewModel, root)
    }

    private static func recoveryOperation(
        item: NativeQueueItem,
        status: NativeDownloadStatus,
        root: URL,
        stem: String,
        phase: String,
        createdAt: Date,
        warnings: [String],
        notices: [String]
    ) throws -> NativeDownloadOperation {
        let output = root.appendingPathComponent("\(stem).flac")
        let albumID = QobuzID("snapshot-album")
        let trackID = QobuzID("snapshot-track")
        let partial = QobuzDownloadArtifacts.partialURL(
            for: output,
            formatID: 27,
            albumID: albumID,
            trackID: trackID
        )
        let processing = QobuzDownloadArtifacts.processingURL(
            for: output,
            formatID: 27,
            albumID: albumID,
            trackID: trackID
        )
        try Data(repeating: 0x5a, count: 24_576).write(to: partial)
        var operation = NativeDownloadOperation(
            queueID: item.id,
            activityID: UUID(),
            status: status,
            title: item.title
        )
        operation.quality = .hiRes
        operation.audioFormat = .hiRes
        operation.downloadRootPath = root.path
        operation.phase = phase
        operation.progress = status.canRetry ? 0.71 : 0.43
        operation.completedTracks = status.canRetry ? 8 : 3
        operation.totalTracks = 12
        operation.albumBytesWritten = status.canRetry ? 418_000_000 : 176_000_000
        operation.errorMessage = status.failureMessage
        operation.warnings = warnings
        operation.notices = notices
        operation.outputURLs = [output]
        operation.checkpoint = QobuzDownloadCheckpoint(
            phase: .transferringAudio,
            trackID: trackID,
            albumID: albumID,
            outputURL: processing
        )
        operation.activityCreatedAt = createdAt
        return operation
    }

    private static func archiveTrack(
        _ relativePath: String,
        formatID: Int,
        integrity: QobuzArchiveIntegrity
    ) -> QobuzArchiveTrack {
        QobuzArchiveTrack(
            relativePath: relativePath,
            qobuzTrackID: UUID().uuidString,
            qobuzAlbumID: UUID().uuidString,
            formatID: formatID,
            bitDepth: formatID == 6 ? 16 : 24,
            samplingRate: formatID == 6 ? 44.1 : 96,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSHA256: integrity == .missing ? nil : String(repeating: "b", count: 64),
            byteCount: 48_000_000,
            integrity: integrity,
            archiveKind: .album,
            isLibraryManaged: true
        )
    }
}

struct LibraryProblemsSnapshotView: View {
    let snapshot: QobuzArchiveSnapshot
    @State private var selection: Set<QobuzArchiveTrack.ID>

    init(snapshot: QobuzArchiveSnapshot) {
        self.snapshot = snapshot
        _selection = State(initialValue: Set(snapshot.nativeFileProblems.prefix(2).map(\.id)))
    }

    var body: some View {
        NativeLibraryProblemsView(
            snapshot: snapshot,
            isScanning: false,
            isDownloading: false,
            selection: $selection,
            onRepair: { _ in },
            onRepairAll: {},
            onRevealTrack: { _ in },
            onRevealIssue: { _ in }
        )
    }
}

struct LibraryWorkspaceSnapshotView: View {
    let snapshot: QobuzArchiveSnapshot
    @State private var section = NativeLibrarySection.problems

    var body: some View {
        VStack(spacing: 0) {
            NativeLibrarySummaryBar(
                snapshot: snapshot,
                isScanning: false,
                section: $section
            )
            Divider()
            LibraryProblemsSnapshotView(snapshot: snapshot)
        }
    }
}
