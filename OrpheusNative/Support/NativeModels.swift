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

struct NativeQueueItem: Codable, Identifiable, Equatable {
    let id: UUID
    let request: QobuzRequest
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var expectedTrackIDs: [QobuzID]?
    var repairTarget: QobuzArchiveTrack?
    var downloadQuality: QobuzQuality?
    var downloadRootPath: String?
    /// Metadata used by the queue inspector. `nil` until the item has been
    /// resolved for preview.
    var trackPlan: [NativeQueueTrack]?
    /// `nil` means every available track. An explicit empty set intentionally
    /// prevents the item from starting until the user selects something.
    var selectedTrackIDs: Set<QobuzID>?

    var canonicalURL: URL { request.canonicalURL }

    var availableTrackIDs: Set<QobuzID> {
        if let trackPlan {
            return Set(trackPlan.filter(\.isAvailable).map(\.qobuzID))
        }
        return Set(expectedTrackIDs ?? [])
    }

    var effectiveSelectedTrackIDs: Set<QobuzID> {
        selectedTrackIDs ?? availableTrackIDs
    }

    var hasSelectedTracks: Bool {
        if repairTarget != nil { return true }
        if selectedTrackIDs != nil { return !effectiveSelectedTrackIDs.isEmpty }
        // An unresolved artist/label plan is still valid and will be resolved
        // by the engine when it reaches the front of the queue.
        return trackPlan == nil || !availableTrackIDs.isEmpty
    }

    init(request: QobuzRequest, title: String? = nil) {
        id = UUID()
        self.request = request
        self.title = title ?? "\(request.kindName) \(request.id.rawValue)"
        subtitle = request.kindName
        repairTarget = nil
        if case .track(let id) = request {
            expectedTrackIDs = [id]
        }
    }

    init(repairTarget: QobuzArchiveTrack) {
        id = UUID()
        request = .track(QobuzID(repairTarget.qobuzTrackID))
        title = URL(fileURLWithPath: repairTarget.relativePath).lastPathComponent
        subtitle = "Repair · \(repairTarget.audioFormat?.displayName ?? "Format \(repairTarget.formatID)")"
        expectedTrackIDs = [QobuzID(repairTarget.qobuzTrackID)]
        self.repairTarget = repairTarget
        // Repairs use the archive's exact format, not the user's maximum policy.
        downloadQuality = nil
    }
}

struct NativeQueueTrack: Codable, Identifiable, Equatable {
    let id: String
    let qobuzID: QobuzID
    let title: String
    let subtitle: String
    let duration: Int?
    let position: Int
    let unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }
}

struct NativeQueuePreflight: Equatable {
    let total: Int?
    let available: Int?
    let selected: Int?
    let unavailable: Int
    let verified: Int
    let problems: Int

    var needsDownload: Int? {
        selected.map { max($0 - verified, 0) }
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

struct NativeLibraryFileProblem: Identifiable, Equatable {
    let track: QobuzArchiveTrack
    let diagnostic: String?

    var id: QobuzArchiveTrack.ID { track.id }

    var reasonTitle: String {
        switch track.integrity {
        case .verified: "Verified"
        case .missing: "Missing"
        case .checksumMismatch: "Changed"
        case .metadataConflict: "Conflict"
        case .unreadable: "Unreadable"
        }
    }

    var reasonDetail: String {
        switch track.integrity {
        case .verified:
            "The file matches its recorded checksum."
        case .missing:
            "The archived audio file is no longer present at this path."
        case .checksumMismatch:
            "The file no longer matches its recorded SHA-256 checksum."
        case .metadataConflict:
            "The provenance record and checksums.sha256 disagree."
        case .unreadable:
            diagnostic ?? "The file could not be read or hashed."
        }
    }

    var systemImage: String {
        switch track.integrity {
        case .verified: "checkmark.seal.fill"
        case .missing: "questionmark.folder"
        case .checksumMismatch: "exclamationmark.triangle.fill"
        case .metadataConflict: "arrow.trianglehead.2.clockwise.rotate.90"
        case .unreadable: "xmark.octagon.fill"
        }
    }

    var isAutomaticallyRepairable: Bool {
        track.integrity != .verified && track.audioFormat != nil
    }

    var repairabilityDetail: String {
        if isAutomaticallyRepairable {
            return "Orpheus can restore this exact Qobuz track at its archived quality and path."
        }
        return "Archived format \(track.formatID) is not supported for automatic repair."
    }
}

struct NativeLibraryIndexProblem: Identifiable, Equatable {
    let id: String
    let relativePath: String
    let message: String
}

extension QobuzArchiveSnapshot {
    var nativeFileProblems: [NativeLibraryFileProblem] {
        let diagnostics = Dictionary(grouping: issues, by: \.relativePath)
        return tracks.compactMap { track in
            guard track.integrity != .verified else { return nil }
            return NativeLibraryFileProblem(
                track: track,
                diagnostic: diagnostics[track.relativePath]?.first?.message
            )
        }
    }

    var nativeIndexProblems: [NativeLibraryIndexProblem] {
        let trackProblemPaths = Set(nativeFileProblems.map { $0.track.relativePath })
        return issues.enumerated().compactMap { offset, issue in
            guard !trackProblemPaths.contains(issue.relativePath) else { return nil }
            return NativeLibraryIndexProblem(
                id: "\(offset):\(issue.relativePath):\(issue.message)",
                relativePath: issue.relativePath,
                message: issue.message
            )
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

struct NativeDownloadActivity: Codable, Identifiable, Equatable {
    let id: UUID
    let queueID: UUID
    var title: String
    /// User maximum for normal downloads. Repairs instead use `audioFormat`.
    var quality: QobuzQuality? = nil
    /// Exact archived format requested by a repair.
    var audioFormat: QobuzAudioFormat? = nil
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
    /// Informational delivery details such as an intentional quality fallback.
    /// Optional keeps sessions written by older builds decodable.
    var notices: [String]?
    var warnings: [String] = []
    var errorMessage: String?
    var outputURL: URL?

    var informationalNotices: [String] { notices ?? [] }
}

struct NativePartialDownload: Equatable {
    let url: URL
    let bytes: Int64
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
