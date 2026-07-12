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

enum NativeQueueStatus: Equatable {
    case ready
    case loading
    case downloading
    case completed
    case failed(String)
    case cancelled

    var canStart: Bool {
        switch self {
        case .ready, .failed, .cancelled: true
        case .loading, .downloading, .completed: false
        }
    }
}

struct NativeQueueItem: Identifiable, Equatable {
    let id: UUID
    let request: QobuzRequest
    let canonicalURL: URL
    var title: String
    var subtitle: String
    var status: NativeQueueStatus

    init(request: QobuzRequest, title: String? = nil) {
        id = UUID()
        self.request = request
        canonicalURL = request.canonicalURL
        self.title = title ?? "\(request.kindName) \(request.id.rawValue)"
        subtitle = request.kindName
        status = .ready
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

enum NativeActivityStatus: Equatable {
    case queued
    case resolving
    case downloading
    case tagging
    case validating
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .resolving, .downloading, .tagging, .validating: true
        default: false
        }
    }
}

struct NativeDownloadActivity: Identifiable, Equatable {
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
    var checksum: String?
    var outputURL: URL?
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
