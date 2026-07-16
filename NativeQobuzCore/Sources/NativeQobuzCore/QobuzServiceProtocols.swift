import Foundation

public protocol QobuzCatalogService: Sendable {
    func validateAccount() async throws -> String?
    func track(id: QobuzID) async throws -> QobuzTrack
    func album(id: QobuzID) async throws -> QobuzAlbum
    func playlist(id: QobuzID) async throws -> QobuzPlaylist
    func artist(id: QobuzID) async throws -> QobuzArtistCatalog
    func label(id: QobuzID) async throws -> QobuzLabelCatalog
    func playlistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzPlaylist
    func artistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzArtistCatalog
    func labelPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzLabelCatalog
    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo
}

public extension QobuzCatalogService {
    func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        throw NativeQobuzError.unavailable("Label browsing is not supported by this catalog service.")
    }

    func playlistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzPlaylist {
        try await playlist(id: id)
    }

    func artistPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzArtistCatalog {
        try await artist(id: id)
    }

    func labelPage(id: QobuzID, offset: Int, limit: Int) async throws -> QobuzLabelCatalog {
        try await label(id: id)
    }
}

public protocol QobuzBrowsingService: Sendable {
    func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int,
        offset: Int
    ) async throws -> QobuzSearchResults
}

public extension QobuzBrowsingService {
    func search(
        _ query: String,
        category: QobuzSearchCategory,
        limit: Int
    ) async throws -> QobuzSearchResults {
        try await search(query, category: category, limit: limit, offset: 0)
    }
}

public struct QobuzRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let maximumRetryAfter: Duration
    public let jitterFraction: Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(350),
        maximumRetryAfter: Duration = .seconds(120),
        jitterFraction: Double = 0.1
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maximumRetryAfter = maximumRetryAfter
        self.jitterFraction = min(max(jitterFraction, 0), 0.5)
    }

    public static let standard = QobuzRetryPolicy()
}
