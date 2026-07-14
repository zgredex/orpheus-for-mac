import Foundation
import NativeQobuzCore

enum Format {
    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }
}

enum CountryFlag {
    static func emoji(for code: String) -> String? {
        let normalized = code.uppercased()
        guard normalized.count == 2 else { return nil }
        let scalars = normalized.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return scalars.map(String.init).joined()
    }
}

extension QobuzQuality {
    var displayName: String {
        switch self {
        case .hiRes: "Hi-Res FLAC"
        case .lossless: "Lossless FLAC"
        case .mp3: "MP3 320 kbps"
        }
    }
}

extension QobuzReleaseType {
    var displayName: String {
        switch self {
        case .album: "Album"
        case .single: "Single"
        case .ep: "EP"
        case .compilation: "Compilation"
        case .live: "Live"
        case .epSingle: "EP / Single"
        default:
            rawValue
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }
}

/// The only app-side formatting authority for Qobuz catalog metadata. Views
/// choose which facts fit their density, but never reinterpret raw API values.
enum CatalogFormat {
    static func albumFacts(
        _ metadata: QobuzAlbumCatalogMetadata,
        trackCount: Int? = nil,
        label: String? = nil,
        includeGenre: Bool = true
    ) -> [String] {
        var values: [String] = []
        append(metadata.subtitle, to: &values)
        append(metadata.releaseType?.displayName, to: &values)
        if let releaseDate = metadata.releaseDate {
            append(String(releaseDate.prefix(4)), to: &values)
        }
        if includeGenre { append(metadata.genres.first, to: &values) }
        if let channels = metadata.audioCapabilities.maximumChannelCount, channels > 2 {
            values.append("\(channels) channels")
        }
        if let trackCount { values.append("\(trackCount) track\(trackCount == 1 ? "" : "s")") }
        append(label, to: &values)
        return unique(values)
    }

    static func albumSubtitle(
        artist: String,
        metadata: QobuzAlbumCatalogMetadata
    ) -> String {
        unique([artist] + Array(albumFacts(metadata, includeGenre: false).prefix(2)))
            .joined(separator: " · ")
    }

    static func albumMarkers(_ metadata: QobuzAlbumCatalogMetadata) -> [CatalogMarker] {
        var values: [CatalogMarker] = []
        if let isOfficial = metadata.isOfficial {
            values.append(CatalogMarker(
                text: isOfficial ? "Official" : "Unofficial",
                systemImage: isOfficial ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                kind: isOfficial ? .official : .unofficial
            ))
        }
        values.append(contentsOf: metadata.releaseTags.prefix(2).map {
            CatalogMarker(text: humanized($0), systemImage: "tag.fill", kind: .tag)
        })
        values.append(contentsOf: metadata.awards.prefix(2).map {
            CatalogMarker(text: $0.name, systemImage: "rosette", kind: .award)
        })
        return values
    }

    static func playlistFacts(_ metadata: QobuzPlaylistCatalogMetadata) -> [String] {
        var values: [String] = []
        if let createdAt = metadata.createdAt {
            values.append(Date(timeIntervalSince1970: TimeInterval(createdAt)).formatted(.dateTime.year()))
        }
        if let duration = metadata.duration {
            let hours = duration / 3_600
            let minutes = (duration % 3_600) / 60
            values.append(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
        }
        return values
    }

    private static func append(_ value: String?, to values: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        values.append(value)
    }

    private static func unique<S: Sequence>(_ values: S) -> [String] where S.Element == String {
        var seen = Set<String>()
        return values.filter {
            seen.insert($0.folding(options: [.caseInsensitive], locale: .current)).inserted
        }
    }

    private static func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
