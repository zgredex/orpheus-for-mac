import Foundation

enum PreviewState: Equatable {
    case idle
    case loading
    case loadedAlbum(AlbumPreviewInfo)
    case loadedTrack(TrackPreviewInfo)
    case loadedArtist(ArtistPreviewInfo)
    case loadedCollection(CollectionPreviewInfo)
    case regionMismatch(yourRegion: String, blockedRegion: String?)
    case error(String)
}

enum RegionDisplay {
    static func display(_ region: String) -> String {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = trimmed.uppercased()
        guard let flag = flag(for: code) else { return trimmed }
        return "\(flag) \(code)"
    }

    private static func flag(for code: String) -> String? {
        guard code.count == 2 else { return nil }

        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard (65...90).contains(scalar.value),
                  let regionalIndicator = UnicodeScalar(127397 + scalar.value) else {
                return nil
            }
            scalars.append(regionalIndicator)
        }
        return String(scalars)
    }
}

// MARK: - Browse State

enum BrowseRoute: Equatable {
    case idle
    case loading
    case results
    case artistDetail(artist: QobuzSearchArtist, albums: [QobuzAlbumResponse])
    case albumDetail(album: AlbumPreviewInfo, tracks: [QobuzTrackRef])
    case error(String)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

enum BrowseCategory: String, CaseIterable, Identifiable, Hashable {
    case albums, artists, tracks
    var id: Self { self }

    var label: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .tracks: return "Tracks"
        }
    }

    var shortLabel: String {
        switch self {
        case .albums: return "Alb"
        case .artists: return "Art"
        case .tracks: return "Trk"
        }
    }

    var iconName: String {
        switch self {
        case .albums: return "square.stack"
        case .artists: return "person.crop.circle"
        case .tracks: return "music.note"
        }
    }

    var searchType: SearchType {
        switch self {
        case .albums:
            return .album
        case .artists:
            return .artist
        case .tracks:
            return .track
        }
    }
}

enum BrowseLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct BrowseCategoryResult: Equatable {
    var albums: [QobuzAlbumResponse] = []
    var artists: [QobuzSearchArtist] = []
    var tracks: [QobuzTrackResponse] = []
    var unavailableCount: Int = 0
    var state: BrowseLoadState = .idle

    var count: Int {
        max(albums.count, artists.count, tracks.count)
    }

    mutating func load() {
        state = .loaded
    }

    mutating func fail(_ message: String) {
        state = .failed(message)
    }
}

struct BrowseResults: Equatable {
    var albums = BrowseCategoryResult()
    var artists = BrowseCategoryResult()
    var tracks = BrowseCategoryResult()

    static var empty: BrowseResults {
        BrowseResults()
    }

    static func loadingAll() -> BrowseResults {
        BrowseResults(
            albums: BrowseCategoryResult(state: .loading),
            artists: BrowseCategoryResult(state: .loading),
            tracks: BrowseCategoryResult(state: .loading)
        )
    }

    subscript(category: BrowseCategory) -> BrowseCategoryResult {
        get {
            switch category {
            case .albums: return albums
            case .artists: return artists
            case .tracks: return tracks
            }
        }
        set {
            switch category {
            case .albums: albums = newValue
            case .artists: artists = newValue
            case .tracks: tracks = newValue
            }
        }
    }

    func count(for category: BrowseCategory) -> Int {
        self[category].count
    }
}

struct QueuedLink: Identifiable, Equatable {
    let id: UUID
    let originalURL: String
    let canonicalURL: String
    let parsed: QobuzURLParseResult
    var title: String?
    var subtitle: String?
    var coverURL: String?
    var state: QueueItemState
    var cachedPreview: PreviewState?
    var downloadID: UUID?

    init(
        id: UUID = UUID(),
        originalURL: String,
        canonicalURL: String,
        parsed: QobuzURLParseResult,
        title: String?,
        subtitle: String?,
        coverURL: String?,
        state: QueueItemState,
        cachedPreview: PreviewState?,
        downloadID: UUID?
    ) {
        self.id = id
        self.originalURL = originalURL
        self.canonicalURL = canonicalURL
        self.parsed = parsed
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.state = state
        self.cachedPreview = cachedPreview
        self.downloadID = downloadID
    }

    static func invalid(url: String) -> QueuedLink {
        QueuedLink(
            originalURL: url,
            canonicalURL: url,
            parsed: .invalid,
            title: "Invalid Qobuz URL",
            subtitle: url,
            coverURL: nil,
            state: .invalid("Not a recognized Qobuz URL."),
            cachedPreview: .error("Not a recognized Qobuz URL."),
            downloadID: nil
        )
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return parsed == .invalid ? "Invalid Qobuz URL" : parsed.contentTypeName
    }

    var displaySubtitle: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return canonicalURL
    }
}

enum QueueItemState: Equatable {
    case ready
    case loadingMetadata
    case metadataFailed(String)
    case invalid(String)
    case queued
    case downloading(UUID)
    case completed(UUID)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading:
            return true
        default:
            return false
        }
    }

    var isMetadataMutable: Bool {
        switch self {
        case .ready, .loadingMetadata, .metadataFailed:
            return true
        default:
            return false
        }
    }

    var canStart: Bool {
        switch self {
        case .ready, .metadataFailed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .ready:
            return "Ready"
        case .loadingMetadata:
            return "Loading"
        case .metadataFailed:
            return "Preview failed"
        case .invalid:
            return "Invalid"
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    let queueID: UUID?
    let url: String
    let title: String
    var status: DownloadStatus
    var startedAt: Date = Date()
    var phase: DownloadPhase = .starting
    var progress: Double = 0
    var speed: String?
    var downloaded: String?
    var total: String?
    var completedUnits: Int = 0
    var totalUnits: Int?
    var progressUnit: DownloadProgressUnit
    var resolvedOutputURL: URL?

    var unitProgressLabel: String? {
        guard let totalUnits, totalUnits > 1 else { return nil }
        return "\(min(completedUnits, totalUnits))/\(totalUnits) \(progressUnit.pluralName)"
    }

    var percentProgressLabel: String {
        "\(Int(Self.clampedFraction(progress) * 100))%"
    }

    var transferProgressLabel: String? {
        guard let downloaded, let total, !downloaded.isEmpty, !total.isEmpty else { return nil }
        return "\(downloaded)/\(total)"
    }

    var progressDetailLabels: [String] {
        var labels: [String] = []
        if status == .downloading {
            labels.append(phase.label)
        }
        if let unitProgressLabel {
            labels.append(unitProgressLabel)
        }
        labels.append(percentProgressLabel)
        if let transferProgressLabel {
            labels.append(transferProgressLabel)
        }
        return labels
    }

    var speedBadgeLabel: String? {
        guard case .downloading = status,
              let speed = speed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speed.isEmpty else {
            return nil
        }
        return speed
    }

    func aggregateProgress(fileFraction: Double) -> Double {
        let fileFraction = Self.clampedFraction(fileFraction)
        guard let totalUnits, totalUnits > 1 else { return fileFraction }

        let completed = min(max(completedUnits, 0), totalUnits)
        let aggregate = (Double(completed) + fileFraction) / Double(totalUnits)
        return Self.clampedFraction(aggregate)
    }

    static func unitProgress(completed: Int, total: Int?) -> Double? {
        guard let total, total > 0 else { return nil }
        let completed = min(max(completed, 0), total)
        return Self.clampedFraction(Double(completed) / Double(total))
    }

    static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

enum DownloadPhase: Equatable {
    case starting
    case preparingMedia
    case downloading

    var label: String {
        switch self {
        case .starting:
            return "Starting"
        case .preparingMedia:
            return "Preparing media"
        case .downloading:
            return "Downloading"
        }
    }
}

struct DownloadPreflightContext {
    let ids: [UUID]
    let items: [QueuedLink]
    let quality: String
}

enum DownloadProgressUnit: Equatable {
    case tracks
    case albums

    var pluralName: String {
        switch self {
        case .tracks:
            return "tracks"
        case .albums:
            return "albums"
        }
    }
}

enum DownloadStatus: Equatable {
    case queued
    case downloading
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var isClearable: Bool {
        !isActive
    }

    var isRetryable: Bool {
        switch self {
        case .failed, .cancelled:
            return true
        case .queued, .downloading, .completed:
            return false
        }
    }
}

enum DownloadPreflightError: LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

extension QobuzURLParseResult {
    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}
