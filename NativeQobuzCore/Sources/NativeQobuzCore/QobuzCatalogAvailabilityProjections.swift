import Foundation

public enum QobuzArtistReleaseRelationship: Equatable, Sendable {
    case official
    case appearance
}

public enum QobuzAvailabilityIssue: Equatable, Sendable {
    case notDisplayable
    case notStreamable
    case notPurchasable
}

public extension QobuzCatalogAvailability {
    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        if displayable == .unavailable { return .notDisplayable }
        if streamable == .unavailable { return .notStreamable }
        if purchasable == .unavailable { return .notPurchasable }
        return nil
    }
}

public extension QobuzAlbumSummary {
    var catalogMetadata: QobuzAlbumCatalogMetadata {
        QobuzAlbumCatalogMetadata(
            releaseType: releaseType,
            releaseTags: releaseTags,
            genres: genresList.isEmpty ? [genre].compactMap { $0 } : genresList,
            isOfficial: isOfficial,
            releaseDate: releaseDate,
            subtitle: subtitle,
            awards: awards,
            audioCapabilities: QobuzCatalogAudioCapabilities(
                maximumBitDepth: maximumBitDepth,
                maximumSamplingRate: maximumSamplingRate,
                maximumChannelCount: maximumChannelCount
            ),
            availability: QobuzCatalogAvailability(
                streamable: streamable,
                downloadable: downloadable,
                displayable: displayable,
                purchasable: purchasable
            )
        )
    }

    var albumArtistDisplayName: String {
        let value = mainArtists.map(\.name).joined(separator: ", ")
        return value.isEmpty ? (artist?.name ?? "Unknown Artist") : value
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        catalogMetadata.availability.accountAvailabilityIssue
    }

    var accountAvailabilityIsUnknown: Bool {
        catalogMetadata.availability.hasUnknownAccountAccess
    }
}

public extension QobuzTrack {
    var catalogMetadata: QobuzTrackCatalogMetadata {
        QobuzTrackCatalogMetadata(
            audioCapabilities: QobuzCatalogAudioCapabilities(
                maximumBitDepth: maximumBitDepth,
                maximumSamplingRate: maximumSamplingRate,
                maximumChannelCount: maximumChannelCount
            ),
            availability: QobuzCatalogAvailability(
                streamable: streamable,
                downloadable: downloadable,
                displayable: true,
                purchasable: purchasable
            ),
            copyright: copyright
        )
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        catalogMetadata.availability.accountAvailabilityIssue
    }

    var accountAvailabilityIsUnknown: Bool {
        catalogMetadata.availability.hasUnknownAccountAccess
    }
}

public extension QobuzAlbum {
    var catalogMetadata: QobuzAlbumCatalogMetadata {
        QobuzAlbumCatalogMetadata(
            releaseType: releaseType,
            releaseTags: releaseTags,
            genres: genresList.isEmpty ? [genre].compactMap { $0 } : genresList,
            isOfficial: isOfficial,
            releaseDate: releaseDate,
            subtitle: subtitle,
            catchline: catchline,
            editorialDescription: albumDescription,
            awards: awards,
            audioCapabilities: QobuzCatalogAudioCapabilities(
                maximumBitDepth: maximumBitDepth,
                maximumSamplingRate: maximumSamplingRate,
                maximumChannelCount: maximumChannelCount
            ),
            availability: QobuzCatalogAvailability(
                streamable: streamable,
                downloadable: downloadable,
                displayable: displayable,
                purchasable: purchasable
            )
        )
    }

    var albumArtistDisplayName: String {
        mainArtists.map(\.name).joined(separator: ", ")
    }

    var accountAvailabilityIssue: QobuzAvailabilityIssue? {
        catalogMetadata.availability.accountAvailabilityIssue
    }

    var accountAvailabilityIsUnknown: Bool {
        catalogMetadata.availability.hasUnknownAccountAccess
    }

    var availableTracks: [QobuzTrack] {
        tracks.filter { $0.accountAvailabilityIssue == nil }
    }

    var unavailableTrackCount: Int {
        tracks.count - availableTracks.count
    }

    var unknownTrackCount: Int {
        tracks.count { $0.accountAvailabilityIssue == nil && $0.accountAvailabilityIsUnknown }
    }
}

public extension QobuzPlaylist {
    var catalogMetadata: QobuzPlaylistCatalogMetadata {
        QobuzPlaylistCatalogMetadata(
            artworkURL: artworkURL,
            editorialDescription: playlistDescription,
            duration: duration,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tracksCount: tracksCount ?? tracksTotal ?? tracks.count
        )
    }

    var availableTracks: [QobuzTrack] {
        tracks.filter { $0.accountAvailabilityIssue == nil }
    }

    var unavailableTrackCount: Int {
        tracks.count - availableTracks.count
    }

    var unknownTrackCount: Int {
        tracks.count { $0.accountAvailabilityIssue == nil && $0.accountAvailabilityIsUnknown }
    }
}

public extension QobuzLabelCatalog {
    var availableAlbums: [QobuzAlbum] {
        albums.filter { $0.accountAvailabilityIssue == nil }
    }

    var unknownAlbumCount: Int {
        albums.count { $0.accountAvailabilityIssue == nil && $0.accountAvailabilityIsUnknown }
    }
}

public extension QobuzArtistCatalog {
    var availableAlbums: [QobuzAlbum] {
        albums.filter { $0.accountAvailabilityIssue == nil }
    }

    var unknownAlbumCount: Int {
        albums.count { $0.accountAvailabilityIssue == nil && $0.accountAvailabilityIsUnknown }
    }

    var allOfficialAlbums: [QobuzAlbum] {
        albums.filter { relationship(of: $0) == .official }
    }

    var officialAlbums: [QobuzAlbum] {
        allOfficialAlbums.filter { $0.accountAvailabilityIssue == nil }
    }

    var unknownOfficialAlbumCount: Int {
        allOfficialAlbums.count { $0.accountAvailabilityIssue == nil && $0.accountAvailabilityIsUnknown }
    }

    var appearanceAlbums: [QobuzAlbum] {
        availableAlbums.filter { relationship(of: $0) == .appearance }
    }

    func relationship(of album: QobuzAlbum) -> QobuzArtistReleaseRelationship {
        if album.mainArtists.contains(where: { $0.id == id }) {
            return .official
        }
        if let albumArtistID = album.artist.id {
            return albumArtistID == id ? .official : .appearance
        }
        return normalizedArtistName(album.artist.name) == normalizedArtistName(name)
            ? .official
            : .appearance
    }

    private func normalizedArtistName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
