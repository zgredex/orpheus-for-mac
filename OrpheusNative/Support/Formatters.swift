import Foundation

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
