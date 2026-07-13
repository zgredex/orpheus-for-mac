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
}

enum BrowsePageContent: Equatable {
    case loading
    case album(QobuzAlbum)
    case artist(QobuzArtistCatalog)
    case error(String)
}

/// One entry in the browse pane's drill-down stack.
struct BrowsePage: Identifiable, Equatable {
    let id: UUID
    let destination: BrowseDestination
    var content: BrowsePageContent
}

enum NativeBrowseCategory: String, CaseIterable, Hashable, Identifiable {
    case albums = "Albums"
    case artists = "Artists"
    case tracks = "Tracks"

    var id: Self { self }

    var coreValue: QobuzSearchCategory {
        switch self {
        case .albums: .albums
        case .artists: .artists
        case .tracks: .tracks
        }
    }
}
