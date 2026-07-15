import NativeQobuzCore

enum NativePreviewState: Equatable {
    case empty
    case loading
    case album(QobuzAlbum)
    case track(QobuzTrack)
    case playlist(QobuzPlaylist)
    case artist(QobuzArtistCatalog)
    case label(QobuzLabelCatalog)
    case error(String)
}
