import NativeQobuzCore

struct NativeCatalogAvailabilityPolicy {
    var accountRegion: String?

    func availability(for album: QobuzAlbum) -> NativeBrowseAvailability {
        if let issue = album.accountAvailabilityIssue {
            return .unavailable(message(for: issue, item: "This album"))
        }
        let available = album.availableTracks.count
        let unavailable = album.unavailableTrackCount
        guard available > 0 else {
            return .unavailable("None of this album's tracks are available for \(accountDescription).")
        }
        guard unavailable > 0 else { return .available }
        let trackWord = unavailable == 1 ? "track is" : "tracks are"
        return .partial(
            "\(available) of \(album.tracks.count) tracks are available for \(accountDescription). "
                + "The \(unavailable) unavailable \(trackWord) shown below and will be skipped."
        )
    }

    func availability(for track: QobuzTrack) -> NativeBrowseAvailability {
        guard let issue = track.accountAvailabilityIssue else { return .available }
        return .unavailable(message(for: issue, item: "This track"))
    }

    func availability(for playlist: QobuzPlaylist) -> NativeBrowseAvailability {
        let available = playlist.availableTracks.count
        let unavailable = playlist.unavailableTrackCount
        guard available > 0 else {
            return .unavailable("None of this playlist's tracks are available for \(accountDescription).")
        }
        guard unavailable > 0 else { return .available }
        return .partial(
            "\(available) of \(playlist.tracks.count) tracks are available for \(accountDescription). "
                + "Unavailable tracks are shown below and will be skipped."
        )
    }

    func availability(for artist: QobuzArtistCatalog) -> NativeBrowseAvailability {
        let allOfficial = artist.allOfficialAlbums
        let available = artist.officialAlbums
        guard !available.isEmpty else {
            return .unavailable(
                "Qobuz returned no available official releases for this artist and \(accountDescription)."
            )
        }
        let unavailable = allOfficial.count - available.count
        guard unavailable > 0 else { return .available }
        let releaseWord = unavailable == 1 ? "release is" : "releases are"
        return .partial(
            "\(available.count) of \(allOfficial.count) official releases are available for \(accountDescription). "
                + "The \(unavailable) unavailable \(releaseWord) excluded."
        )
    }

    func availability(for label: QobuzLabelCatalog) -> NativeBrowseAvailability {
        let available = label.availableAlbums.count
        guard available > 0 else {
            return .unavailable("Qobuz returned no albums from this label for \(accountDescription).")
        }
        let total = label.albums.count
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
