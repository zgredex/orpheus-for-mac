import Foundation
@testable import NativeQobuzCore

func testAudioProperties(for format: QobuzAudioFormat) -> AudioStreamProperties {
    switch format {
    case .mp3:
        AudioStreamProperties(container: .mp3, codec: .mp3, bitDepth: nil, samplingRate: 44.1)
    case .lossless:
        AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 16, samplingRate: 44.1)
    case .hiRes96:
        AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 24, samplingRate: 96)
    case .hiRes:
        AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 24, samplingRate: 96)
    }
}

func validatedTestDelivery(for fileInfo: QobuzFileInfo) throws -> QobuzValidatedAudioDelivery {
    try QobuzDeliveryPolicy().validate(
        fileInfo: fileInfo,
        media: testAudioProperties(for: fileInfo.format)
    )
}
