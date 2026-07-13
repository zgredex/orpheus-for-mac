import Foundation
import NativeQobuzCore

struct NativeSettings: Codable, Equatable {
    var downloadPath: String
    var quality: QobuzQuality
}

struct CredentialDraft: Codable, Equatable {
    var appID = ""
    var appSecret = ""
    var authToken = ""

    var coreValue: QobuzCredentials {
        QobuzCredentials(appID: appID, appSecret: appSecret, authToken: authToken)
    }

    var isComplete: Bool { coreValue.isComplete }
}

/// Editable copy of the configuration shown in the settings sheet.
struct SettingsDraft: Equatable {
    var credentials = CredentialDraft()
    var quality: QobuzQuality = .hiRes
    var downloadPath = ""
}

enum NativeQueueStatus: Codable, Equatable {
    case ready
    case loading
    case downloading
    case paused
    case completed
    case failed(String)
    case cancelled

    var canStart: Bool {
        switch self {
        case .ready, .paused, .failed, .cancelled: true
        case .loading, .downloading, .completed: false
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case ready, loading, downloading, paused, completed, failed, cancelled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ready: self = .ready
        case .loading: self = .loading
        case .downloading: self = .downloading
        case .paused: self = .paused
        case .completed: self = .completed
        case .failed: self = .failed(try container.decode(String.self, forKey: .message))
        case .cancelled: self = .cancelled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready: try container.encode(Kind.ready, forKey: .kind)
        case .loading: try container.encode(Kind.loading, forKey: .kind)
        case .downloading: try container.encode(Kind.downloading, forKey: .kind)
        case .paused: try container.encode(Kind.paused, forKey: .kind)
        case .completed: try container.encode(Kind.completed, forKey: .kind)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .cancelled: try container.encode(Kind.cancelled, forKey: .kind)
        }
    }
}

struct NativeQueueItem: Codable, Identifiable, Equatable {
    let id: UUID
    let request: QobuzRequest
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var status: NativeQueueStatus
    var expectedTrackIDs: [QobuzID]?
    var repairTarget: QobuzArchiveTrack?
    var downloadQuality: QobuzQuality?
    var downloadRootPath: String?

    var canonicalURL: URL { request.canonicalURL }

    init(request: QobuzRequest, title: String? = nil) {
        id = UUID()
        self.request = request
        self.title = title ?? "\(request.kindName) \(request.id.rawValue)"
        subtitle = request.kindName
        status = .ready
        repairTarget = nil
        if case .track(let id) = request {
            expectedTrackIDs = [id]
        }
    }

    init(repairTarget: QobuzArchiveTrack) {
        id = UUID()
        request = .track(QobuzID(repairTarget.qobuzTrackID))
        title = URL(fileURLWithPath: repairTarget.relativePath).lastPathComponent
        subtitle = "Repair · \(QobuzQuality(formatID: repairTarget.formatID)?.displayName ?? "Format \(repairTarget.formatID)")"
        status = .ready
        expectedTrackIDs = [QobuzID(repairTarget.qobuzTrackID)]
        self.repairTarget = repairTarget
        downloadQuality = QobuzQuality(formatID: repairTarget.formatID)
    }
}

enum NativeLinkReviewStatus: Codable, Equatable {
    case pending
    case checking
    case available
    case partial(String)
    case unavailable(String)
    case failed(String)

    var message: String? {
        switch self {
        case .partial(let value), .unavailable(let value), .failed(let value): value
        case .pending, .checking, .available: nil
        }
    }

    var isReviewed: Bool {
        switch self {
        case .pending, .checking: false
        case .available, .partial, .unavailable, .failed: true
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case pending, checking, available, partial, unavailable, failed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .checking: self = .checking
        case .available: self = .available
        case .partial: self = .partial(try container.decode(String.self, forKey: .message))
        case .unavailable: self = .unavailable(try container.decode(String.self, forKey: .message))
        case .failed: self = .failed(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try container.encode(Kind.pending, forKey: .kind)
        case .checking: try container.encode(Kind.checking, forKey: .kind)
        case .available: try container.encode(Kind.available, forKey: .kind)
        case .partial(let message):
            try container.encode(Kind.partial, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .unavailable(let message):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

struct NativeLinkInboxItem: Codable, Identifiable, Equatable {
    let id: UUID
    let originalURL: String
    let request: QobuzRequest
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var status: NativeLinkReviewStatus

    init(link: ParsedQobuzLink) {
        id = UUID()
        originalURL = link.original
        request = link.request
        title = "\(link.request.kindName) \(link.request.id.rawValue)"
        subtitle = link.request.kindName
        status = .pending
    }

    var canonicalURL: URL { request.canonicalURL }
}

enum NativeLibraryStatus: Equatable {
    case verified
    case complete(Int)
    case partial(verified: Int, total: Int, problems: Int)
    case indexed(verified: Int, problems: Int)

    init?(_ coverage: QobuzArchiveCoverage) {
        guard coverage.matchedCount > 0 else { return nil }
        if coverage.isComplete {
            if coverage.expectedCount == 1 {
                self = .verified
            } else {
                self = .complete(coverage.expectedCount ?? coverage.verifiedCount)
            }
        } else if let expectedCount = coverage.expectedCount {
            self = .partial(
                verified: coverage.verifiedCount,
                total: expectedCount,
                problems: coverage.problemCount
            )
        } else {
            self = .indexed(
                verified: coverage.verifiedCount,
                problems: coverage.problemCount
            )
        }
    }

    var label: String {
        switch self {
        case .verified:
            "Verified"
        case .complete(let count):
            "\(count)/\(count) verified"
        case .partial(let verified, let total, let problems):
            if verified == 0, problems > 0 { "Needs attention" }
            else { "\(verified)/\(total) verified" }
        case .indexed(let verified, let problems):
            if verified == 0, problems > 0 { "Needs attention" }
            else if problems > 0 { "\(verified) verified · \(problems) issue\(problems == 1 ? "" : "s")" }
            else { "\(verified) verified" }
        }
    }

    var compactLabel: String {
        switch self {
        case .verified: "Verified"
        case .complete: "All verified"
        case .partial(let verified, let total, _): "\(verified)/\(total)"
        case .indexed(let verified, let problems):
            problems > 0 ? "\(problems) issue\(problems == 1 ? "" : "s")" : "\(verified) verified"
        }
    }

    var hasProblems: Bool {
        switch self {
        case .verified, .complete: false
        case .partial(let verified, let total, let problems): problems > 0 || verified < total
        case .indexed(_, let problems): problems > 0
        }
    }
}

enum NativePreviewState: Equatable {
    case empty
    case loading
    case album(QobuzAlbum)
    case track(QobuzTrack)
    case playlist(QobuzPlaylist)
    case artist(QobuzArtistCatalog)
    case label(QobuzLabelCatalog)
    case error(String)
}

enum NativeActivityStatus: Codable, Equatable {
    case queued
    case resolving
    case downloading
    case tagging
    case validating
    case paused
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .resolving, .downloading, .tagging, .validating: true
        default: false
        }
    }

    var isClearable: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case queued, resolving, downloading, tagging, validating, paused, completed, failed, cancelled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .queued: self = .queued
        case .resolving: self = .resolving
        case .downloading: self = .downloading
        case .tagging: self = .tagging
        case .validating: self = .validating
        case .paused: self = .paused
        case .completed: self = .completed
        case .failed: self = .failed(try container.decode(String.self, forKey: .message))
        case .cancelled: self = .cancelled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try container.encode(Kind.queued, forKey: .kind)
        case .resolving: try container.encode(Kind.resolving, forKey: .kind)
        case .downloading: try container.encode(Kind.downloading, forKey: .kind)
        case .tagging: try container.encode(Kind.tagging, forKey: .kind)
        case .validating: try container.encode(Kind.validating, forKey: .kind)
        case .paused: try container.encode(Kind.paused, forKey: .kind)
        case .completed: try container.encode(Kind.completed, forKey: .kind)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .cancelled: try container.encode(Kind.cancelled, forKey: .kind)
        }
    }
}

struct NativeDownloadActivity: Codable, Identifiable, Equatable {
    let id: UUID
    let queueID: UUID
    var title: String
    var quality: QobuzQuality? = nil
    var status: NativeActivityStatus = .queued
    var phase = "Queued"
    var currentTrack: String?
    var progress = 0.0
    var completedTracks = 0
    var totalTracks = 0
    var bytesWritten: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var albumBytesWritten: Int64?
    var checksum: String?
    var warnings: [String] = []
    var outputURL: URL?
}

enum BrowseDestination: Equatable {
    case album(QobuzID)
    case artist(QobuzID)
    case track(QobuzID)
    case playlist(QobuzID)
    case label(QobuzID)
}

enum BrowsePageContent: Equatable {
    case loading
    case album(QobuzAlbum)
    case artist(QobuzArtistCatalog)
    case track(QobuzTrack)
    case playlist(QobuzPlaylist)
    case label(QobuzLabelCatalog)
    case error(String)
}

enum NativeBrowseAvailability: Equatable {
    case checking
    case available
    case partial(String)
    case unavailable(String)

    var allowsQueue: Bool {
        switch self {
        case .available, .partial: true
        case .checking, .unavailable: false
        }
    }

    var message: String? {
        switch self {
        case .partial(let message), .unavailable(let message): message
        case .checking, .available: nil
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// One entry in the browse pane's drill-down stack.
struct BrowsePage: Identifiable, Equatable {
    let id: UUID
    let destination: BrowseDestination
    var content: BrowsePageContent
    var availability: NativeBrowseAvailability = .checking
}

enum NativeBrowseCategory: String, CaseIterable, Hashable, Identifiable {
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
    case tracks = "Tracks"

    var id: Self { self }

    var coreValue: QobuzSearchCategory {
        switch self {
        case .albums: .albums
        case .artists: .artists
        case .playlists: .playlists
        case .tracks: .tracks
        }
    }
}

struct NativeBrowseResults: Equatable {
    private(set) var albums: [QobuzAlbumSummary] = []
    private(set) var artists: [QobuzArtist] = []
    private(set) var playlists: [QobuzPlaylist] = []
    private(set) var tracks: [QobuzTrack] = []
    private var totals: [NativeBrowseCategory: Int] = [:]
    private var nextOffsets: [NativeBrowseCategory: Int] = [:]

    var totalCount: Int {
        albums.count + artists.count + playlists.count + tracks.count
    }

    func count(for category: NativeBrowseCategory) -> Int {
        switch category {
        case .albums: albums.count
        case .artists: artists.count
        case .playlists: playlists.count
        case .tracks: tracks.count
        }
    }

    func total(for category: NativeBrowseCategory) -> Int? {
        totals[category]
    }

    func nextOffset(for category: NativeBrowseCategory) -> Int? {
        nextOffsets[category]
    }

    var reportedTotalCount: Int? {
        guard totals.count == NativeBrowseCategory.allCases.count else { return nil }
        return totals.values.reduce(0, +)
    }

    var hasMoreResults: Bool {
        !nextOffsets.isEmpty
    }

    mutating func replace(_ values: QobuzSearchResults, for category: NativeBrowseCategory) {
        switch category {
        case .albums: albums = values.albums
        case .artists: artists = values.artists
        case .playlists: playlists = values.playlists
        case .tracks: tracks = values.tracks
        }
        updatePageMetadata(values, for: category)
    }

    mutating func append(_ values: QobuzSearchResults, for category: NativeBrowseCategory) {
        switch category {
        case .albums:
            var known = Set(albums.map(\.id))
            albums.append(contentsOf: values.albums.filter { known.insert($0.id).inserted })
        case .artists:
            var known = Set(artists.map { $0.id?.rawValue ?? "name:\($0.name.lowercased())" })
            artists.append(contentsOf: values.artists.filter {
                known.insert($0.id?.rawValue ?? "name:\($0.name.lowercased())").inserted
            })
        case .playlists:
            var known = Set(playlists.map(\.id))
            playlists.append(contentsOf: values.playlists.filter { known.insert($0.id).inserted })
        case .tracks:
            var known = Set(tracks.map(\.id))
            tracks.append(contentsOf: values.tracks.filter { known.insert($0.id).inserted })
        }
        updatePageMetadata(values, for: category)
    }

    var firstNonemptyCategory: NativeBrowseCategory? {
        NativeBrowseCategory.allCases.first { count(for: $0) > 0 }
    }

    private mutating func updatePageMetadata(
        _ values: QobuzSearchResults,
        for category: NativeBrowseCategory
    ) {
        if let total = values.total {
            totals[category] = total
        } else {
            totals.removeValue(forKey: category)
        }
        if let nextOffset = values.nextOffset {
            nextOffsets[category] = nextOffset
        } else {
            nextOffsets.removeValue(forKey: category)
        }
    }
}
