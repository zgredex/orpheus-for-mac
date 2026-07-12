import Foundation

public protocol QobuzOutputPlanning: Sendable {
    func destination(for item: QobuzResolvedTrack, fileInfo: QobuzFileInfo, root: URL) -> URL
}

public struct StandardQobuzOutputPlanner: QobuzOutputPlanning, Sendable {
    public init() {}

    public func destination(for item: QobuzResolvedTrack, fileInfo: QobuzFileInfo, root: URL) -> URL {
        switch item.collection {
        case .track:
            let artist = sanitize(item.track.performer?.name ?? item.album.artist.name)
            let title = sanitize(item.track.displayTitle)
            return root
                .appendingPathComponent(artist, isDirectory: true)
                .appendingPathComponent("\(title).\(fileInfo.fileExtension)")
        case .playlist(_, let title):
            let folder = sanitize(title)
            let width = max(2, String(item.total).count)
            let number = String(format: "%0*d", width, item.position)
            let artist = sanitize(item.track.performer?.name ?? item.album.artist.name)
            let trackTitle = sanitize(item.track.displayTitle)
            return root
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent("\(number). \(artist) - \(trackTitle).\(fileInfo.fileExtension)")
        case .album, .artist:
            let artist = sanitize(item.album.artist.name)
            let album = sanitize(item.album.displayTitle)
            let trackNumber = item.track.trackNumber ?? item.position
            let discNumber = item.track.mediaNumber ?? 1
            let width = max(2, String(item.album.tracksCount ?? item.total).count)
            let number = String(format: "%0*d", width, trackNumber)
            let discPrefix = (item.album.mediaCount ?? 1) > 1 ? "\(discNumber)-" : ""
            let title = sanitize(item.track.displayTitle)
            return root
                .appendingPathComponent(artist, isDirectory: true)
                .appendingPathComponent(album, isDirectory: true)
                .appendingPathComponent("\(discPrefix)\(number). \(title).\(fileInfo.fileExtension)")
        }
    }

    public func sanitize(_ rawValue: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\u{0000}").union(.controlCharacters)
        let scalars = rawValue.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }
        let value = scalars.joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return value.isEmpty ? "Untitled" : String(value.prefix(180))
    }
}
