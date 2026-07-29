import Foundation

enum QobuzArtworkCacheLookup {
    case artwork(EmbeddedArtwork)
    case missing
    case notCached
}

/// Per-operation LRU for embedded covers. Positive and negative results share
/// one owner, preventing repeated fetches without retaining artwork for every
/// album in a large playlist.
final class QobuzArtworkMemoryCache: @unchecked Sendable {
    private enum Value {
        case artwork(EmbeddedArtwork)
        case missing

        var byteCount: Int {
            switch self {
            case .artwork(let artwork): artwork.data.count
            case .missing: 0
            }
        }
    }

    private let maximumBytes: Int
    private let maximumEntries: Int
    private var values: [QobuzID: Value] = [:]
    private var recency: [QobuzID] = []
    private var totalBytes = 0

    init(
        maximumBytes: Int = 48 * 1_024 * 1_024,
        maximumEntries: Int = 32
    ) {
        self.maximumBytes = max(maximumBytes, 0)
        self.maximumEntries = max(maximumEntries, 1)
    }

    func lookup(_ albumID: QobuzID) -> QobuzArtworkCacheLookup {
        guard let value = values[albumID] else { return .notCached }
        touch(albumID)
        return switch value {
        case .artwork(let artwork): .artwork(artwork)
        case .missing: .missing
        }
    }

    func store(_ artwork: EmbeddedArtwork?, for albumID: QobuzID) {
        if let previous = values.removeValue(forKey: albumID) {
            totalBytes -= previous.byteCount
        }
        recency.removeAll { $0 == albumID }
        let value = artwork.map(Value.artwork) ?? .missing
        values[albumID] = value
        recency.append(albumID)
        totalBytes += value.byteCount
        evictIfNeeded()
    }

    var retainedBytes: Int { totalBytes }
    var count: Int { values.count }

    private func touch(_ albumID: QobuzID) {
        recency.removeAll { $0 == albumID }
        recency.append(albumID)
    }

    private func evictIfNeeded() {
        var cursor = 0
        while (values.count > maximumEntries || totalBytes > maximumBytes),
              cursor < recency.count {
            let albumID = recency[cursor]
            cursor += 1
            guard let value = values.removeValue(forKey: albumID) else { continue }
            totalBytes -= value.byteCount
        }
        if cursor > 0 { recency.removeFirst(cursor) }
    }
}
