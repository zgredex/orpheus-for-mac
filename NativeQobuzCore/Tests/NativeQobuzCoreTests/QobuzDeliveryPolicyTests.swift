import Foundation
import XCTest
@testable import NativeQobuzCore

final class QobuzDeliveryPolicyTests: XCTestCase {
    private let policy = QobuzDeliveryPolicy()

    func testCeilingAcceptsEveryFormatAtOrBelowAndRejectsOnlyFormatsAboveIt() throws {
        let allowed: [QobuzQuality: Set<QobuzAudioFormat>] = [
            .mp3: [.mp3],
            .lossless: [.mp3, .lossless],
            .hiRes: Set(QobuzAudioFormat.allCases)
        ]

        for quality in QobuzQuality.allCases {
            for format in QobuzAudioFormat.allCases {
                let fileInfo = QobuzFileInfo(
                    url: URL(string: "https://media.example/audio.\(format.fileExtension)")!,
                    format: format
                )
                if allowed[quality, default: []].contains(format) {
                    XCTAssertNoThrow(
                        try policy.validateCeiling(requestedMaximum: quality, delivered: fileInfo),
                        "\(format) must fit under \(quality)"
                    )
                } else {
                    XCTAssertThrowsError(
                        try policy.validateCeiling(requestedMaximum: quality, delivered: fileInfo),
                        "\(format) must be above \(quality)"
                    )
                }
            }
        }
    }

    func testValidatedDeliveryUsesInspectedPropertiesWhenQobuzOmitsThem() throws {
        let fileInfo = QobuzFileInfo(
            url: URL(string: "https://media.example/audio.flac")!,
            format: .hiRes
        )
        let media = AudioStreamProperties(
            container: .flac,
            codec: .flac,
            bitDepth: 24,
            samplingRate: 176.4
        )

        let delivery = try policy.validate(fileInfo: fileInfo, media: media)

        XCTAssertEqual(delivery.format, .hiRes)
        XCTAssertEqual(delivery.container, .flac)
        XCTAssertEqual(delivery.codec, .flac)
        XCTAssertEqual(delivery.bitDepth, 24)
        XCTAssertEqual(delivery.samplingRate, 176.4)
    }

    func testMP3IgnoresNominalQobuzBitDepthAndKeepsInspectedDepthUnset() throws {
        let delivery = try policy.validate(
            fileInfo: fileInfo(format: .mp3, bitDepth: 16, samplingRate: 44.1),
            media: AudioStreamProperties(
                container: .mp3,
                codec: .mp3,
                bitDepth: nil,
                samplingRate: 44.1
            )
        )

        XCTAssertNil(delivery.bitDepth)
        XCTAssertEqual(delivery.samplingRate, 44.1)
    }

    func testDeliveryRejectsContainerMismatch() {
        assertRejected(
            fileInfo: fileInfo(format: .hiRes, bitDepth: 24, samplingRate: 96),
            media: AudioStreamProperties(container: .mp3, codec: .mp3, bitDepth: 24, samplingRate: 96),
            containing: "requires a FLAC container"
        )
    }

    func testDeliveryRejectsCodecMismatch() {
        assertRejected(
            fileInfo: fileInfo(format: .hiRes, bitDepth: 24, samplingRate: 96),
            media: AudioStreamProperties(container: .flac, codec: .mp3, bitDepth: 24, samplingRate: 96),
            containing: "requires the FLAC codec"
        )
    }

    func testDeliveryRejectsReportedBitDepthMismatch() {
        assertRejected(
            fileInfo: fileInfo(format: .hiRes, bitDepth: 24, samplingRate: 96),
            media: AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 20, samplingRate: 96),
            containing: "reported 24-bit"
        )
    }

    func testDeliveryRejectsReportedSampleRateMismatch() {
        assertRejected(
            fileInfo: fileInfo(format: .hiRes, bitDepth: 24, samplingRate: 192),
            media: AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 24, samplingRate: 96),
            containing: "reported a 192.0 kHz"
        )
    }

    func testDeliveryRejectsPropertiesOutsideExactFormatTier() {
        assertRejected(
            fileInfo: fileInfo(format: .hiRes96),
            media: AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 24, samplingRate: 192),
            containing: "format 7"
        )
        assertRejected(
            fileInfo: fileInfo(format: .lossless),
            media: AudioStreamProperties(container: .flac, codec: .flac, bitDepth: 24, samplingRate: 44.1),
            containing: "format 6"
        )
    }

    private func fileInfo(
        format: QobuzAudioFormat,
        bitDepth: Int? = nil,
        samplingRate: Double? = nil
    ) -> QobuzFileInfo {
        QobuzFileInfo(
            url: URL(string: "https://media.example/audio.\(format.fileExtension)")!,
            format: format,
            bitDepth: bitDepth,
            samplingRate: samplingRate
        )
    }

    private func assertRejected(
        fileInfo: QobuzFileInfo,
        media: AudioStreamProperties,
        containing expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try policy.validate(fileInfo: fileInfo, media: media), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(expectedMessage), error.localizedDescription, file: file, line: line)
        }
    }
}
