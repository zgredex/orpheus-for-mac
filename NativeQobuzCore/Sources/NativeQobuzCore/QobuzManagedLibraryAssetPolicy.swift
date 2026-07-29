import Foundation

enum QobuzManagedLibraryAssetPolicy {
    static let descriptionFilename = "description.txt"
    static let bookletFilename = "Booklet.pdf"
    static let preferredPlaylistExtension = "m3u"
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    static func isSidecar(_ path: LibraryRelativePath) -> Bool {
        guard let name = path.lastComponent else { return false }
        let lowercased = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        return lowercased == descriptionFilename.lowercased()
            || lowercased == bookletFilename.lowercased()
            || EmbeddedArtwork.externalFilenames.contains(lowercased)
            || playlistExtensions.contains(ext)
    }
}
