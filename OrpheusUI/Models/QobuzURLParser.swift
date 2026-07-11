import Foundation

enum QobuzURLParseResult: Equatable {
    case album(String)
    case track(String)
    case playlist(String)
    case artist(String)
    case invalid

    var downloadableURL: String? {
        switch self {
        case .album(let id):
            return "https://open.qobuz.com/album/\(id)"
        case .track(let id):
            return "https://open.qobuz.com/track/\(id)"
        case .playlist(let id):
            return "https://open.qobuz.com/playlist/\(id)"
        case .artist(let id):
            return "https://open.qobuz.com/artist/\(id)"
        case .invalid:
            return nil
        }
    }

    var id: String? {
        switch self {
        case .album(let id), .track(let id), .playlist(let id), .artist(let id):
            return id
        case .invalid:
            return nil
        }
    }

    var contentTypeName: String {
        switch self {
        case .album:
            return "Album"
        case .track:
            return "Track"
        case .playlist:
            return "Playlist"
        case .artist:
            return "Artist"
        case .invalid:
            return "Invalid"
        }
    }

    var iconName: String {
        switch self {
        case .album:
            return "square.stack"
        case .track:
            return "music.note"
        case .playlist:
            return "music.note.list"
        case .artist:
            return "person.crop.circle"
        case .invalid:
            return "exclamationmark.triangle"
        }
    }

    var downloadActionTitle: String {
        switch self {
        case .album:
            return "Download Album"
        case .track:
            return "Download Track"
        case .playlist:
            return "Download Playlist"
        case .artist:
            return "Download Artist Catalog"
        case .invalid:
            return "Download"
        }
    }
}

enum QobuzURLParser {
    static func parse(_ input: String) -> QobuzURLParseResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              host == "open.qobuz.com" || host == "play.qobuz.com" || host == "www.qobuz.com" else {
            return .invalid
        }

        let parts = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else { return .invalid }
        guard let typeIndex = parts.firstIndex(where: { supportedPathTypes.contains($0.lowercased()) }),
              typeIndex < parts.index(before: parts.endIndex) else {
            return .invalid
        }

        let type = parts[typeIndex].lowercased()
        let segmentsAfterType = parts.distance(from: typeIndex, to: parts.endIndex) - 1
        if host == "open.qobuz.com" || host == "play.qobuz.com" {
            guard segmentsAfterType == 1 else { return .invalid }
        } else {
            guard (1...2).contains(segmentsAfterType) else { return .invalid }
        }

        let id = parts[parts.index(before: parts.endIndex)]
        let validIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty,
              id.unicodeScalars.allSatisfy(validIDCharacters.contains) else {
            return .invalid
        }

        switch type {
        case "album":
            return .album(id)
        case "track":
            return .track(id)
        case "playlist":
            return .playlist(id)
        case "artist", "interpreter":
            return .artist(id)
        default:
            return .invalid
        }
    }

    private static let supportedPathTypes = Set(["album", "track", "playlist", "artist", "interpreter"])
}

struct ExtractedQobuzLink: Equatable {
    let originalURL: String
    let canonicalURL: String
    let parsed: QobuzURLParseResult
}

struct LinkExtractionResult: Equatable {
    var links: [ExtractedQobuzLink] = []
    var invalidQobuzURLs: [String] = []
    var duplicateCount: Int = 0
    var ignoredURLCount: Int = 0
}

enum QobuzLinkExtractor {
    static func extract(from text: String, knownCanonicalURLs: Set<String> = []) -> LinkExtractionResult {
        guard let regex = try? NSRegularExpression(pattern: #"(https?://[^\s<>"']+)"#) else {
            return LinkExtractionResult()
        }

        var result = LinkExtractionResult()
        var seen = knownCanonicalURLs
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            let raw = ns.substring(with: match.range(at: 1))
            let candidate = cleanCandidate(raw)
            guard !candidate.isEmpty else { continue }

            guard isQobuzURL(candidate) else {
                result.ignoredURLCount += 1
                continue
            }

            let parsed = QobuzURLParser.parse(candidate)
            guard let canonical = parsed.downloadableURL else {
                result.invalidQobuzURLs.append(candidate)
                continue
            }

            guard !seen.contains(canonical) else {
                result.duplicateCount += 1
                continue
            }

            seen.insert(canonical)
            result.links.append(ExtractedQobuzLink(
                originalURL: candidate,
                canonicalURL: canonical,
                parsed: parsed
            ))
        }

        return result
    }

    private static func cleanCandidate(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.unicodeScalars.last,
              CharacterSet(charactersIn: ".,;:!?)]}\"'").contains(last) {
            value.removeLast()
        }
        return value
    }

    private static func isQobuzURL(_ input: String) -> Bool {
        guard let components = URLComponents(string: input),
              let host = components.host?.lowercased() else {
            return false
        }
        return host == "open.qobuz.com" || host == "play.qobuz.com" || host == "www.qobuz.com"
    }
}
