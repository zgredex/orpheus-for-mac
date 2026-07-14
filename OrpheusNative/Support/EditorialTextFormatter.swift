import AppKit
import Foundation

/// Converts Qobuz's small HTML editorial fragments into native attributed text.
/// API models retain the original response as the catalog source of truth; this
/// formatter is a presentation-only projection and never mutates cached data.
enum EditorialTextFormatter {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()

    static func attributedText(from source: String?) -> AttributedString? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
            return nil
        }

        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }

        let rendered = render(source)
        guard rendered.length > 0 else { return nil }
        cache.setObject(rendered, forKey: key, cost: rendered.length * 2)
        return AttributedString(rendered)
    }

    private static func render(_ source: String) -> NSAttributedString {
        if !source.contains("<"), !source.contains("&") {
            return NSAttributedString(string: source, attributes: [.font: baseFont()])
        }

        let parsed = source.data(using: .utf8).flatMap { data in
            try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
        }
        let value = NSMutableAttributedString(attributedString: parsed ?? fallback(source))
        normalizeWhitespace(in: value)
        trimWhitespace(in: value)
        applyNativePresentation(to: value)
        return value
    }

    private static func applyNativePresentation(to value: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: value.length)
        guard fullRange.length > 0 else { return }

        var fontRuns: [(NSRange, NSFontTraitMask)] = []
        value.enumerateAttribute(.font, in: fullRange) { font, range, _ in
            let traits = (font as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            fontRuns.append((range, traits))
        }

        for key: NSAttributedString.Key in [
            .font, .foregroundColor, .backgroundColor, .link, .paragraphStyle,
            .underlineStyle, .strikethroughStyle
        ] {
            value.removeAttribute(key, range: fullRange)
        }
        value.addAttribute(.font, value: baseFont(), range: fullRange)

        for (range, traits) in fontRuns {
            let weight: NSFont.Weight = traits.contains(.boldFontMask) ? .semibold : .regular
            var font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: weight)
            if traits.contains(.italicFontMask) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            value.addAttribute(.font, value: font, range: range)
        }
    }

    private static func normalizeWhitespace(in value: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: value.length)
        value.mutableString.replaceOccurrences(of: "\u{00a0}", with: " ", range: fullRange)
        while value.mutableString.range(of: "\n\n\n").location != NSNotFound {
            value.mutableString.replaceOccurrences(
                of: "\n\n\n",
                with: "\n\n",
                range: NSRange(location: 0, length: value.length)
            )
        }
    }

    private static func trimWhitespace(in value: NSMutableAttributedString) {
        let string = value.string as NSString
        let content = CharacterSet.whitespacesAndNewlines.inverted
        let first = string.rangeOfCharacter(from: content)
        guard first.location != NSNotFound else {
            value.deleteCharacters(in: NSRange(location: 0, length: value.length))
            return
        }
        let last = string.rangeOfCharacter(from: content, options: .backwards)
        let contentEnd = NSMaxRange(last)
        if contentEnd < value.length {
            value.deleteCharacters(in: NSRange(location: contentEnd, length: value.length - contentEnd))
        }
        if first.location > 0 {
            value.deleteCharacters(in: NSRange(location: 0, length: first.location))
        }
    }

    private static func fallback(_ source: String) -> NSAttributedString {
        let stripped = source
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return NSAttributedString(string: stripped, attributes: [.font: baseFont()])
    }

    private static func baseFont() -> NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }
}
