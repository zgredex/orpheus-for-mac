import Foundation

public protocol QobuzCatalogService: Sendable {
    func validateAccount() async throws -> String?
    func track(id: QobuzID) async throws -> QobuzTrack
    func album(id: QobuzID) async throws -> QobuzAlbum
    func playlist(id: QobuzID) async throws -> QobuzPlaylist
    func artist(id: QobuzID) async throws -> QobuzArtistCatalog
    func label(id: QobuzID) async throws -> QobuzLabelCatalog
    func fileInfo(trackID: QobuzID, format: QobuzAudioFormat) async throws -> QobuzFileInfo
}

public extension QobuzCatalogService {
    func label(id: QobuzID) async throws -> QobuzLabelCatalog {
        throw NativeQobuzError.unavailable("Label browsing is not supported by this catalog service.")
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

    public init(maxAttempts: Int = 3, baseDelay: Duration = .milliseconds(350)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
    }

    public static let standard = QobuzRetryPolicy()
}
