import Foundation

public protocol QobuzOutputPlanning: Sendable {
    func destination(for item: QobuzResolvedTrack, fileInfo: QobuzFileInfo, root: URL) -> URL
    func sanitize(_ rawValue: String) -> String
}

public struct StandardQobuzOutputPlanner: QobuzOutputPlanning, Sendable {
    public init() {}

    public func destination(for item: QobuzResolvedTrack, fileInfo: QobuzFileInfo, root: URL) -> URL {
        // Every logical collection points at one canonical physical album file.
        // The library manifest keeps standalone tracks and playlists distinct.
        let artist = sanitize(item.album.artist.name)
        let album = sanitize(item.album.displayTitle)
        let trackNumber = item.track.trackNumber ?? item.position
        let discNumber = item.track.mediaNumber ?? 1
        let width = max(2, String(item.album.tracksCount ?? item.total).count)
        let number = String(format: "%0*d", width, trackNumber)
        let discPrefix = (item.album.mediaCount ?? 1) > 1 ? "\(discNumber)-" : ""
        let title = sanitize(item.track.displayTitle)
        let filename = QobuzFilenameComponent.make(
            stem: "\(discPrefix)\(number). \(title)",
            pathExtension: fileInfo.fileExtension
        )
        return root
            .appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(album, isDirectory: true)
            .appendingPathComponent(filename)
    }

    public func sanitize(_ rawValue: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\u{0000}").union(.controlCharacters)
        let scalars = rawValue.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }
        let value = scalars.joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return value.isEmpty
            ? "Untitled"
            : QobuzFilenameComponent.truncate(
                value,
                toUTF8Bytes: QobuzFilenameComponent.sanitizedStemBytes
            )
    }
}
