import Foundation

public struct ParsedQobuzLink: Equatable, Sendable {
    public let original: String
    public let request: QobuzRequest

    public init(original: String, request: QobuzRequest) {
        self.original = original
        self.request = request
    }

    public var canonicalURL: URL { request.canonicalURL }
}

public struct QobuzLinkExtraction: Equatable, Sendable {
    public let links: [ParsedQobuzLink]
    public let invalidQobuzURLs: [String]
    public let duplicateCount: Int
    public let ignoredURLCount: Int

    public init(
        links: [ParsedQobuzLink] = [],
        invalidQobuzURLs: [String] = [],
        duplicateCount: Int = 0,
        ignoredURLCount: Int = 0
    ) {
        self.links = links
        self.invalidQobuzURLs = invalidQobuzURLs
        self.duplicateCount = duplicateCount
        self.ignoredURLCount = ignoredURLCount
    }
}

public enum QobuzLinkParser {
    public static func parse(_ input: String) -> ParsedQobuzLink? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              supportedHosts.contains(host) else {
            return nil
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let kindIndex = parts.firstIndex(where: { supportedKinds.contains($0.lowercased()) }),
              kindIndex < parts.index(before: parts.endIndex) else {
            return nil
        }
        let tailCount = parts.distance(from: kindIndex, to: parts.endIndex) - 1
        if host == "www.qobuz.com" {
            let kind = parts[kindIndex].lowercased()
            let allowed = kind == "label" ? (1...3).contains(tailCount) : (1...2).contains(tailCount)
            guard allowed else { return nil }
        } else {
            guard tailCount == 1 else { return nil }
        }
        let rawID = parts.last ?? ""
        let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !rawID.isEmpty, rawID.unicodeScalars.allSatisfy(valid.contains) else { return nil }
        let id = QobuzID(rawID)
        let request: QobuzRequest
        switch parts[kindIndex].lowercased() {
        case "track": request = .track(id)
        case "album": request = .album(id)
        case "playlist", "playlists": request = .playlist(id)
        case "artist", "interpreter": request = .artist(id)
        case "label": request = .label(id)
        default: return nil
        }
        return ParsedQobuzLink(original: value, request: request)
    }

    public static func extract(
        from text: String,
        knownCanonicalURLs: Set<String> = []
    ) -> QobuzLinkExtraction {
        guard let expression = try? NSRegularExpression(pattern: #"(https?://[^\s<>\"']+)"#) else {
            return QobuzLinkExtraction()
        }
        let source = text as NSString
        var links: [ParsedQobuzLink] = []
        var invalid: [String] = []
        var duplicates = 0
        var ignored = 0
        var seen = knownCanonicalURLs
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let candidate = clean(source.substring(with: match.range(at: 1)))
            guard isQobuz(candidate) else {
                ignored += 1
                continue
            }
            guard let parsed = parse(candidate) else {
                invalid.append(candidate)
                continue
            }
            let canonical = parsed.canonicalURL.absoluteString
            guard seen.insert(canonical).inserted else {
                duplicates += 1
                continue
            }
            links.append(parsed)
        }
        return QobuzLinkExtraction(
            links: links,
            invalidQobuzURLs: invalid,
            duplicateCount: duplicates,
            ignoredURLCount: ignored
        )
    }

    private static func clean(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")
        while let last = value.unicodeScalars.last, punctuation.contains(last) { value.removeLast() }
        return value
    }

    private static func isQobuz(_ value: String) -> Bool {
        guard let host = URLComponents(string: value)?.host?.lowercased() else { return false }
        return supportedHosts.contains(host)
    }

    private static let supportedHosts = Set(["open.qobuz.com", "play.qobuz.com", "www.qobuz.com"])
    private static let supportedKinds = Set(["track", "album", "playlist", "playlists", "artist", "interpreter", "label"])
}
