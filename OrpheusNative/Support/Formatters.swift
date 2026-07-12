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
