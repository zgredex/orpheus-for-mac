import Foundation
import NativeQobuzCore

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

    func total(for category: NativeBrowseCategory) -> Int? { totals[category] }
    func nextOffset(for category: NativeBrowseCategory) -> Int? { nextOffsets[category] }
    var hasMoreResults: Bool { !nextOffsets.isEmpty }

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
        if let total = values.total { totals[category] = total }
        else { totals.removeValue(forKey: category) }
        if let nextOffset = values.nextOffset { nextOffsets[category] = nextOffset }
        else { nextOffsets.removeValue(forKey: category) }
    }
}
