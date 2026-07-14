import NativeQobuzCore
import SwiftUI

/// Shared quality language for catalog capability, requested downloads, and archived files.
struct QualityBadge: View {
    enum Kind: Hashable {
        case catalog(bitDepth: Int?, samplingRate: Double?, hiRes: Bool)
        case target(QobuzQuality)
        case exact(QobuzAudioFormat)
        case archive(formatID: Int, bitDepth: Int?, samplingRate: Double?)
        case mixed
        case explicitContent

        static func catalog(_ album: QobuzAlbum) -> Self {
            .catalog(
                bitDepth: album.maximumBitDepth,
                samplingRate: album.maximumSamplingRate,
                hiRes: album.hiresStreamable
            )
        }

        static func catalog(_ album: QobuzAlbumSummary) -> Self {
            .catalog(
                bitDepth: album.maximumBitDepth,
                samplingRate: album.maximumSamplingRate,
                hiRes: album.hiresStreamable
            )
        }

        static func catalog(_ track: QobuzTrack) -> Self {
            let bitDepth = track.maximumBitDepth ?? track.album?.maximumBitDepth
            let samplingRate = track.maximumSamplingRate ?? track.album?.maximumSamplingRate
            return .catalog(
                bitDepth: bitDepth,
                samplingRate: samplingRate,
                hiRes: track.album?.hiresStreamable == true
                    || (bitDepth ?? 0) > 16
                    || (samplingRate ?? 0) > 48
            )
        }

        static func catalog(_ track: QobuzTrack, fallback album: QobuzAlbum) -> Self {
            let bitDepth = track.maximumBitDepth ?? album.maximumBitDepth
            let samplingRate = track.maximumSamplingRate ?? album.maximumSamplingRate
            return .catalog(
                bitDepth: bitDepth,
                samplingRate: samplingRate,
                hiRes: album.hiresStreamable
                    || (bitDepth ?? 0) > 16
                    || (samplingRate ?? 0) > 48
            )
        }

        static func archive(_ track: QobuzArchiveTrack) -> Self {
            .archive(
                formatID: track.formatID,
                bitDepth: track.bitDepth,
                samplingRate: track.samplingRate
            )
        }

        var color: Color {
            switch tier {
            case .hiRes: .orange
            case .lossless: .teal
            case .mp3: .blue
            case .mixed: .indigo
            case .marker: .secondary
            }
        }

        var text: String {
            switch self {
            case .catalog(let bitDepth, let samplingRate, let hiRes):
                return Self.audioText(
                    tier: Self.catalogTier(bitDepth: bitDepth, samplingRate: samplingRate, hiRes: hiRes),
                    bitDepth: bitDepth,
                    samplingRate: samplingRate
                )
            case .target(let quality):
                switch quality {
                case .hiRes: return "Hi-Res FLAC"
                case .lossless: return "Lossless FLAC"
                case .mp3: return "MP3 320"
                }
            case .exact(let format):
                return format.displayName
            case .archive(let formatID, let bitDepth, let samplingRate):
                let tier = Self.archiveTier(
                    formatID: formatID,
                    bitDepth: bitDepth,
                    samplingRate: samplingRate
                )
                return Self.audioText(tier: tier, bitDepth: bitDepth, samplingRate: samplingRate)
            case .mixed: return "Mixed quality"
            case .explicitContent: return "E"
            }
        }

        var helpText: String {
            switch self {
            case .catalog: "Maximum quality Qobuz reports for this catalog item: \(text)"
            case .target: "Requested download quality: \(text)"
            case .exact: "Exact Qobuz audio format requested for this repair: \(text)"
            case .archive: "Quality recorded for this downloaded file: \(text)"
            case .mixed: "This downloaded collection contains more than one audio quality."
            case .explicitContent: "Explicit content"
            }
        }

        private var tier: Tier {
            switch self {
            case .catalog(let bitDepth, let samplingRate, let hiRes):
                return Self.catalogTier(bitDepth: bitDepth, samplingRate: samplingRate, hiRes: hiRes)
            case .target(let quality):
                switch quality {
                case .hiRes: return .hiRes
                case .lossless: return .lossless
                case .mp3: return .mp3
                }
            case .exact(let format):
                return Self.tier(for: format)
            case .archive(let formatID, let bitDepth, let samplingRate):
                return Self.archiveTier(
                    formatID: formatID,
                    bitDepth: bitDepth,
                    samplingRate: samplingRate
                )
            case .mixed: return .mixed
            case .explicitContent: return .marker
            }
        }

        private static func catalogTier(bitDepth: Int?, samplingRate: Double?, hiRes: Bool) -> Tier {
            if hiRes || (bitDepth ?? 0) > 16 || (samplingRate ?? 0) > 48 { return .hiRes }
            return .lossless
        }

        private static func tier(for format: QobuzAudioFormat) -> Tier {
            switch format {
            case .mp3: .mp3
            case .lossless: .lossless
            case .hiRes96, .hiRes: .hiRes
            }
        }

        private static func archiveTier(
            formatID: Int,
            bitDepth: Int?,
            samplingRate: Double?
        ) -> Tier {
            if let format = QobuzAudioFormat(formatID: formatID) {
                return tier(for: format)
            }
            if let bitDepth, let samplingRate, bitDepth > 16 || samplingRate > 48 { return .hiRes }
            return .lossless
        }

        private static func audioText(
            tier: Tier,
            bitDepth: Int?,
            samplingRate: Double?
        ) -> String {
            let name: String = switch tier {
            case .hiRes: "Hi-Res"
            case .lossless: "Lossless"
            case .mp3: "MP3 320"
            case .mixed: "Mixed quality"
            case .marker: ""
            }
            guard tier != .mp3, let bitDepth, let samplingRate else { return name }
            let rate = samplingRate.formatted(.number.precision(.fractionLength(0...1)))
            return "\(name) · \(bitDepth)/\(rate)"
        }

        private enum Tier: Equatable {
            case hiRes
            case lossless
            case mp3
            case mixed
            case marker
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(kind.color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.color.opacity(0.12), in: Capsule())
            .overlay { Capsule().stroke(kind.color.opacity(0.22), lineWidth: 0.5) }
            .help(kind.helpText)
            .accessibilityLabel(kind.helpText)
    }
}
