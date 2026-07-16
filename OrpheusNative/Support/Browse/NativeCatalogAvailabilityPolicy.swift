import NativeQobuzCore

struct NativeCatalogAvailabilityPolicy {
    var accountRegion: String?

    func availability(
        for content: BrowsePageContent,
        collectionComplete: Bool = true
    ) -> NativeBrowseAvailability {
        switch content {
        case .album(let value): availability(for: value)
        case .artist(let value): availability(for: value, collectionComplete: collectionComplete)
        case .track(let value): availability(for: value)
        case .playlist(let value): availability(for: value, collectionComplete: collectionComplete)
        case .label(let value): availability(for: value, collectionComplete: collectionComplete)
        case .loading, .error: .checking
        }
    }

    func availability(for album: QobuzAlbum) -> NativeBrowseAvailability {
        if let issue = album.accountAvailabilityIssue {
            return .unavailable(message(for: issue, item: "This album"))
        }
        let available = album.availableTracks.count
        let unavailable = album.unavailableTrackCount
        guard available > 0 else {
            if album.unknownTrackCount > 0 {
                return .unknown("Qobuz did not report availability for this album's tracks. Downloading will verify access.")
            }
            return .unavailable("None of this album's tracks are available for \(accountDescription).")
        }
        if unavailable == 0, album.unknownTrackCount > 0 {
            return .unknown("Some track availability was not reported by Qobuz. Downloading will verify access.")
        }
        guard unavailable > 0 else { return .available }
        let trackWord = unavailable == 1 ? "track is" : "tracks are"
        return .partial(
            "\(available) of \(album.tracks.count) tracks are available for \(accountDescription). "
                + "The \(unavailable) unavailable \(trackWord) shown below and will be skipped."
        )
    }

    func availability(for track: QobuzTrack) -> NativeBrowseAvailability {
        if let issue = track.accountAvailabilityIssue {
            return .unavailable(message(for: issue, item: "This track"))
        }
        if track.accountAvailabilityIsUnknown {
            return .unknown("Qobuz did not report this track's availability. Downloading will verify access.")
        }
        return .available
    }

    func availability(
        for playlist: QobuzPlaylist,
        collectionComplete: Bool = true
    ) -> NativeBrowseAvailability {
        let available = playlist.availableTracks.count
        let unavailable = playlist.unavailableTrackCount
        guard available > 0 else {
            if playlist.unknownTrackCount > 0 || !collectionComplete {
                return .unknown("Playlist availability is not fully known yet. Loading or downloading will verify access.")
            }
            return .unavailable("None of this playlist's tracks are available for \(accountDescription).")
        }
        if unavailable == 0, playlist.unknownTrackCount > 0 || !collectionComplete {
            return .unknown("Some playlist availability is still unknown. Downloading will verify access.")
        }
        guard unavailable > 0 else { return .available }
        return .partial(
            "\(available) of \(playlist.tracks.count) tracks are available for \(accountDescription). "
                + "Unavailable tracks are shown below and will be skipped."
        )
    }

    func availability(
        for artist: QobuzArtistCatalog,
        collectionComplete: Bool = true
    ) -> NativeBrowseAvailability {
        let allOfficial = artist.allOfficialAlbums
        let available = artist.officialAlbums
        guard !available.isEmpty else {
            if artist.unknownOfficialAlbumCount > 0 || !collectionComplete {
                return .unknown("Artist availability is not fully known yet. Load more releases or add the artist to verify access.")
            }
            return .unavailable(
                "Qobuz returned no available official releases for this artist and \(accountDescription)."
            )
        }
        let unavailable = allOfficial.count - available.count
        if unavailable == 0, artist.unknownOfficialAlbumCount > 0 || !collectionComplete {
            return .unknown("More releases or availability details are still available from Qobuz.")
        }
        guard unavailable > 0 else { return .available }
        let releaseWord = unavailable == 1 ? "release is" : "releases are"
        return .partial(
            "\(available.count) of \(allOfficial.count) official releases are available for \(accountDescription). "
                + "The \(unavailable) unavailable \(releaseWord) excluded."
        )
    }

    func availability(
        for label: QobuzLabelCatalog,
        collectionComplete: Bool = true
    ) -> NativeBrowseAvailability {
        let available = label.availableAlbums.count
        guard available > 0 else {
            if label.unknownAlbumCount > 0 || !collectionComplete {
                return .unknown("Label availability is not fully known yet. Load more albums or add the label to verify access.")
            }
            return .unavailable("Qobuz returned no albums from this label for \(accountDescription).")
        }
        let total = label.albums.count
        if available == total, label.unknownAlbumCount > 0 || !collectionComplete {
            return .unknown("More albums or availability details are still available from Qobuz.")
        }
        guard available < total else { return .available }
        return .partial(
            "\(available) of \(total) label albums are available for \(accountDescription). "
                + "Unavailable albums are excluded."
        )
    }

    func unavailabilityMessage(for track: QobuzTrack) -> String? {
        guard let issue = track.accountAvailabilityIssue else { return nil }
        return message(for: issue, item: "Track")
    }

    func errorMessage(_ error: Error) -> String {
        guard let qobuzError = error as? NativeQobuzError else {
            return error.localizedDescription
        }
        switch qobuzError {
        case .unavailable:
            return "Qobuz did not return this item for \(accountDescription). "
                + "It may belong to another region, be unavailable, or have been removed."
        case .emptyCollection:
            return "Qobuz returned no available tracks for this item and \(accountDescription)."
        default:
            return error.localizedDescription
        }
    }

    func failureAvailability(
        for error: Error,
        message: String
    ) -> NativeBrowseAvailability {
        guard let qobuzError = error as? NativeQobuzError else { return .checking }
        switch qobuzError {
        case .unavailable, .emptyCollection:
            return .unavailable(message)
        default:
            return .checking
        }
    }

    private var accountDescription: String {
        guard let accountRegion else { return "this Qobuz account" }
        let region = accountRegion.uppercased()
        if let flag = CountryFlag.emoji(for: accountRegion) {
            return "the \(flag) \(region) account"
        }
        return "the \(region) account"
    }

    private func message(for issue: QobuzAvailabilityIssue, item: String) -> String {
        switch issue {
        case .notDisplayable:
            return "\(item) is not present in the catalog for \(accountDescription). "
                + "It may belong to another region or have been removed."
        case .notStreamable:
            return "\(item) is not streamable for \(accountDescription)."
        case .notPurchasable:
            return "\(item) is not purchasable in the store for \(accountDescription)."
        }
    }
}
