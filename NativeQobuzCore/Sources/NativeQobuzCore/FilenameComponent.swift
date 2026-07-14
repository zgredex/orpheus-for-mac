import Foundation

/// APFS-safe construction for one filename component. Truncation happens on
/// Character boundaries and is measured in UTF-8 bytes, never character count.
public enum QobuzFilenameComponent {
    public static let maximumBytes = 255
    public static let sanitizedStemBytes = 180

    public static func truncate(_ value: String, toUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.count, limit))
        var used = 0
        for character in value {
            let text = String(character)
            let bytes = text.utf8.count
            guard used + bytes <= limit else { break }
            result += text
            used += bytes
        }
        return result
    }

    public static func make(
        prefix: String = "",
        stem: String,
        suffix: String = "",
        pathExtension: String = "",
        maximumBytes: Int = maximumBytes
    ) -> String {
        let extensionPart = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let fixedBytes = prefix.utf8.count + suffix.utf8.count + extensionPart.utf8.count
        let fittedStem = truncate(stem, toUTF8Bytes: max(maximumBytes - fixedBytes, 0))
        return prefix + (fittedStem.isEmpty ? "Untitled" : fittedStem) + suffix + extensionPart
    }
}
