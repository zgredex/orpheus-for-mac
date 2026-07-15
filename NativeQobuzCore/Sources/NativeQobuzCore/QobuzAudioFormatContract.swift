import Foundation

enum QobuzBitDepthRequirement: Sendable {
    case notApplicable
    case exactly(Int)
    case greaterThan(Int)

    var isApplicable: Bool {
        if case .notApplicable = self { return false }
        return true
    }

    func accepts(_ bitDepth: Int?) -> Bool {
        switch self {
        case .notApplicable:
            true
        case .exactly(let expected):
            bitDepth == expected
        case .greaterThan(let minimum):
            bitDepth.map { $0 > minimum } ?? false
        }
    }
}

struct QobuzAudioFormatContract: Sendable {
    let rank: Int
    let container: AudioContainerFormat
    let codec: AudioCodecFormat
    let bitDepth: QobuzBitDepthRequirement
    let maximumSamplingRate: Double
    let inconsistencyDescription: String

    func accepts(_ media: AudioStreamProperties) -> Bool {
        bitDepth.accepts(media.bitDepth) && media.samplingRate <= maximumSamplingRate + 0.01
    }
}

extension QobuzAudioFormat {
    /// Authoritative technical contract and ordering for each exact Qobuz
    /// wire format. All ceiling and media-consistency decisions use this map.
    var deliveryContract: QobuzAudioFormatContract {
        switch self {
        case .mp3:
            QobuzAudioFormatContract(
                rank: 0,
                container: .mp3,
                codec: .mp3,
                bitDepth: .notApplicable,
                maximumSamplingRate: 48,
                inconsistencyDescription: "Qobuz MP3 format 5 must contain MP3 audio at no more than 48 kHz."
            )
        case .lossless:
            QobuzAudioFormatContract(
                rank: 1,
                container: .flac,
                codec: .flac,
                bitDepth: .exactly(16),
                maximumSamplingRate: 48,
                inconsistencyDescription: "Qobuz lossless format 6 must contain 16-bit FLAC audio at no more than 48 kHz."
            )
        case .hiRes96:
            QobuzAudioFormatContract(
                rank: 2,
                container: .flac,
                codec: .flac,
                bitDepth: .greaterThan(16),
                maximumSamplingRate: 96,
                inconsistencyDescription: "Qobuz Hi-Res format 7 must contain FLAC audio above 16-bit at no more than 96 kHz."
            )
        case .hiRes:
            QobuzAudioFormatContract(
                rank: 3,
                container: .flac,
                codec: .flac,
                bitDepth: .greaterThan(16),
                maximumSamplingRate: 192,
                inconsistencyDescription: "Qobuz Hi-Res format 27 must contain FLAC audio above 16-bit at no more than 192 kHz."
            )
        }
    }
}
