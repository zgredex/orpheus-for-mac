import Foundation

extension QobuzCollection {
    var archiveKind: QobuzArchiveKind {
        switch self {
        case .album, .artist, .label: .album
        case .track: .track
        case .playlist: .playlist
        }
    }

    var usesAlbumFolders: Bool {
        true
    }

    var writesAlbumCollectionAssets: Bool {
        switch self {
        case .album, .artist, .label: true
        case .track, .playlist: false
        }
    }
}

extension QobuzAlbum {
    public var originalArtworkURL: URL? {
        guard let source = image?.bestURL else { return nil }
        let value = source.absoluteString
        guard let separator = value.lastIndex(of: "_") else { return source }
        return URL(string: String(value[..<separator]) + "_org.jpg") ?? source
    }
}
