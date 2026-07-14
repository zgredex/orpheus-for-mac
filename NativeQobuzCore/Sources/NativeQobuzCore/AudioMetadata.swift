import Foundation
import ImageIO

public struct EmbeddedArtwork: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let depth: Int

    public init(data: Data, mimeType: String, width: Int = 0, height: Int = 0, depth: Int = 0) {
        self.data = data
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.depth = depth
    }

    public init(data: Data, response: URLResponse?) {
        self = Self.inspecting(data: data, mimeType: response?.mimeType)
    }

    public static func inspecting(data: Data, mimeType: String? = nil) -> EmbeddedArtwork {
        let detectedType = mimeType ?? Self.detectMimeType(data) ?? "image/jpeg"
        var width = 0
        var height = 0
        var depth = 0
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if width > 0 && height > 0 {
                depth = detectedType == "image/png" ? 32 : 24
            }
        }
        return EmbeddedArtwork(data: data, mimeType: detectedType, width: width, height: height, depth: depth)
    }

    private static func detectMimeType(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return nil
    }
}

/// Layer 1: the complete allow-list for portable FLAC Vorbis Comments and MP3
/// ID3 tags. Catalog-only fields and Qobuz provenance do not belong here.
public struct QobuzAudioMetadata: Equatable, Sendable {
    public let title: String
    public let album: String
    public let artists: [String]
    public let albumArtists: [String]
    public let composer: String?
    public let credits: [String: [String]]
    public let releaseDate: String?
    public let trackNumber: Int?
    public let totalTracks: Int?
    public let discNumber: Int?
    public let totalDiscs: Int?
    public let isrc: String?
    public let barcode: String?
    public let label: String?
    public let copyright: String?
    public let genre: String?
    public let isExplicit: Bool

    public init(
        title: String,
        album: String,
        artists: [String],
        albumArtist: String,
        albumArtists: [String]? = nil,
        composer: String? = nil,
        credits: [String: [String]] = [:],
        releaseDate: String? = nil,
        trackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        totalDiscs: Int? = nil,
        isrc: String? = nil,
        barcode: String? = nil,
        label: String? = nil,
        copyright: String? = nil,
        genre: String? = nil,
        isExplicit: Bool = false
    ) {
        self.title = title
        self.album = album
        self.artists = artists
        let values = (albumArtists ?? [albumArtist]).filter { !$0.isEmpty }
        var seenAlbumArtists = Set<String>()
        let uniqueAlbumArtists = values.filter { seenAlbumArtists.insert($0).inserted }
        self.albumArtists = uniqueAlbumArtists.isEmpty ? [albumArtist] : uniqueAlbumArtists
        self.composer = composer
        self.credits = credits
        self.releaseDate = releaseDate
        self.trackNumber = trackNumber
        self.totalTracks = totalTracks
        self.discNumber = discNumber
        self.totalDiscs = totalDiscs
        self.isrc = isrc
        self.barcode = barcode
        self.label = label
        self.copyright = copyright
        self.genre = genre
        self.isExplicit = isExplicit
    }

    public init(item: QobuzResolvedTrack) {
        let performer = item.track.performer?.name ?? item.album.artist.name
        let parsed = Self.parsePerformers(item.track.performers, mainArtist: performer)
        self.init(
            title: item.track.displayTitle,
            album: item.album.displayTitle,
            artists: parsed.artists,
            albumArtist: item.album.artist.name,
            albumArtists: item.album.mainArtists.map(\.name),
            composer: item.track.composer?.name,
            credits: parsed.credits,
            releaseDate: item.album.releaseDate,
            trackNumber: item.track.trackNumber,
            totalTracks: item.album.tracksCount ?? item.album.tracks.count,
            discNumber: item.track.mediaNumber,
            totalDiscs: item.album.mediaCount,
            isrc: item.track.isrc,
            barcode: item.album.upc,
            label: item.album.label,
            copyright: item.track.copyright ?? item.album.copyright,
            genre: item.album.genre,
            isExplicit: item.track.parentalWarning || item.album.parentalWarning
        )
    }

    public var albumArtist: String { albumArtists.first ?? "" }

    private static func parsePerformers(
        _ rawValue: String?,
        mainArtist: String
    ) -> (artists: [String], credits: [String: [String]]) {
        var artists = [mainArtist]
        var credits: [String: [String]] = [:]
        guard let rawValue else { return (artists, credits) }

        for contribution in rawValue.components(separatedBy: " - ") {
            let fields = contribution.components(separatedBy: ", ")
            guard let name = fields.first, !name.isEmpty else { continue }
            var roles = Array(fields.dropFirst())
            let artistRoles = Set(["MainArtist", "FeaturedArtist", "Artist"])
            if roles.contains(where: artistRoles.contains), !artists.contains(name) {
                artists.append(name)
            }
            roles.removeAll(where: artistRoles.contains)
            for role in roles where !role.isEmpty {
                if !(credits[role] ?? []).contains(name) { credits[role, default: []].append(name) }
            }
        }
        return (artists, credits)
    }
}

public protocol AudioMetadataWriting: Sendable {
    func write(metadata: QobuzAudioMetadata, artwork: EmbeddedArtwork?, to fileURL: URL) throws
}

public struct NativeAudioMetadataWriter: AudioMetadataWriting, Sendable {
    private let id3Writer = ID3v23Writer()
    private let flacWriter = FLACMetadataWriter()

    public init() {}

    public func write(metadata: QobuzAudioMetadata, artwork: EmbeddedArtwork?, to fileURL: URL) throws {
        let started = Date()
        let metadataValues = [
            "filePath": fileURL.path,
            "format": fileURL.pathExtension.lowercased(),
            "title": metadata.title,
            "artworkEmbedded": String(artwork != nil)
        ]
        qobuzLog.info("metadata.audio", "Audio metadata write started", metadata: metadataValues)
        do {
            switch fileURL.pathExtension.lowercased() {
            case "mp3":
                try id3Writer.write(metadata: metadata, artwork: artwork, to: fileURL)
            case "flac":
                try flacWriter.write(metadata: metadata, artwork: artwork, to: fileURL)
            default:
                throw NativeQobuzError.fileSystem("Unsupported audio format: \(fileURL.pathExtension)")
            }
            qobuzLog.notice(
                "metadata.audio",
                "Audio metadata write completed",
                metadata: metadataValues.merging([
                    "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
                ]) { _, new in new }
            )
        } catch {
            qobuzLog.error(
                "metadata.audio",
                "Audio metadata write failed",
                metadata: metadataValues.merging([
                    "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
                ]) { _, new in new },
                error: error
            )
            throw error
        }
    }
}
