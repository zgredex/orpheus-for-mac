import Foundation

/// Shared catalog capability data. These values describe what Qobuz advertises
/// and must never be mistaken for the specifications of a downloaded file.
public struct QobuzCatalogAudioCapabilities: Equatable, Sendable {
    public let maximumBitDepth: Int?
    public let maximumSamplingRate: Double?
    public let maximumChannelCount: Int?

    public init(
        maximumBitDepth: Int? = nil,
        maximumSamplingRate: Double? = nil,
        maximumChannelCount: Int? = nil
    ) {
        self.maximumBitDepth = maximumBitDepth
        self.maximumSamplingRate = maximumSamplingRate
        self.maximumChannelCount = maximumChannelCount
    }
}

public enum QobuzAvailabilityState: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown

    public init(advertised value: Bool?) {
        switch value {
        case .some(true): self = .available
        case .some(false): self = .unavailable
        case .none: self = .unknown
        }
    }
}

public struct QobuzCatalogAvailability: Equatable, Sendable {
    public let streamable: QobuzAvailabilityState
    public let downloadable: QobuzAvailabilityState
    public let displayable: QobuzAvailabilityState
    public let purchasable: QobuzAvailabilityState

    public init(
        streamable: Bool?,
        downloadable: Bool?,
        displayable: Bool? = nil,
        purchasable: Bool? = nil
    ) {
        self.streamable = QobuzAvailabilityState(advertised: streamable)
        self.downloadable = QobuzAvailabilityState(advertised: downloadable)
        self.displayable = QobuzAvailabilityState(advertised: displayable)
        self.purchasable = QobuzAvailabilityState(advertised: purchasable)
    }

    public var hasUnknownAccountAccess: Bool {
        // Qobuz has always treated `purchasable` as optional: its absence does
        // not make subscription playback/download access indeterminate. The
        // catalog-presence and streamability flags are the authoritative
        // account-access signals used by the app.
        displayable == .unknown || streamable == .unknown
    }
}

/// Layer 2: a derived, non-persisted view of album data intended for browsing,
/// filtering, and badges. The album/summary remains the only stored source.
public struct QobuzAlbumCatalogMetadata: Equatable, Sendable {
    public let releaseType: QobuzReleaseType?
    public let releaseTags: [String]
    public let genres: [String]
    public let isOfficial: Bool?
    public let releaseDate: String?
    public let subtitle: String?
    public let catchline: String?
    public let editorialDescription: String?
    public let awards: [QobuzEditorialAward]
    public let audioCapabilities: QobuzCatalogAudioCapabilities
    public let availability: QobuzCatalogAvailability

    public init(
        releaseType: QobuzReleaseType? = nil,
        releaseTags: [String] = [],
        genres: [String] = [],
        isOfficial: Bool? = nil,
        releaseDate: String? = nil,
        subtitle: String? = nil,
        catchline: String? = nil,
        editorialDescription: String? = nil,
        awards: [QobuzEditorialAward] = [],
        audioCapabilities: QobuzCatalogAudioCapabilities = .init(),
        availability: QobuzCatalogAvailability
    ) {
        self.releaseType = releaseType
        self.releaseTags = Self.uniqueNonempty(releaseTags)
        self.genres = Self.uniqueNonempty(genres)
        self.isOfficial = isOfficial
        self.releaseDate = releaseDate
        self.subtitle = subtitle
        self.catchline = catchline
        self.editorialDescription = editorialDescription
        self.awards = awards
        self.audioCapabilities = audioCapabilities
        self.availability = availability
    }

    private static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.folding(options: [.caseInsensitive], locale: .current)).inserted else {
                return nil
            }
            return value
        }
    }
}

/// Layer 2 track projection. It deliberately contains catalog display data,
/// not portable audio tags or downloaded-file provenance.
public struct QobuzTrackCatalogMetadata: Equatable, Sendable {
    public let audioCapabilities: QobuzCatalogAudioCapabilities
    public let availability: QobuzCatalogAvailability
    public let copyright: String?

    public init(
        audioCapabilities: QobuzCatalogAudioCapabilities,
        availability: QobuzCatalogAvailability,
        copyright: String?
    ) {
        self.audioCapabilities = audioCapabilities
        self.availability = availability
        self.copyright = copyright
    }
}

/// Layer 2 playlist projection. Standard Qobuz artwork and legacy rectangle
/// artwork are resolved once by the canonical playlist model.
public struct QobuzPlaylistCatalogMetadata: Equatable, Sendable {
    public let artworkURL: URL?
    public let editorialDescription: String?
    public let duration: Int?
    public let createdAt: Int?
    public let updatedAt: Int?
    public let tracksCount: Int?

    public init(
        artworkURL: URL?,
        editorialDescription: String?,
        duration: Int?,
        createdAt: Int?,
        updatedAt: Int?,
        tracksCount: Int?
    ) {
        self.artworkURL = artworkURL
        self.editorialDescription = editorialDescription
        self.duration = duration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tracksCount = tracksCount
    }
}
