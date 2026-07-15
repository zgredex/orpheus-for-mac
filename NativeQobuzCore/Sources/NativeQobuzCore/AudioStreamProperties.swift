import AudioToolbox
import Foundation

public enum AudioContainerFormat: String, Codable, Equatable, Sendable {
    case flac
    case mp3
}

public enum AudioCodecFormat: String, Codable, Equatable, Sendable {
    case flac
    case mp3
}

/// Properties read from the completed audio file, never inferred from its
/// extension or copied from Qobuz's response.
public struct AudioStreamProperties: Equatable, Sendable {
    public let container: AudioContainerFormat
    public let codec: AudioCodecFormat
    public let bitDepth: Int?
    public let samplingRate: Double

    public init(
        container: AudioContainerFormat,
        codec: AudioCodecFormat,
        bitDepth: Int?,
        samplingRate: Double
    ) {
        self.container = container
        self.codec = codec
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
    }
}

struct AudioToolboxStreamInspector: Sendable {
    func inspect(_ fileURL: URL) throws -> AudioStreamProperties {
        var audioFile: AudioFileID?
        try requireSuccess(
            AudioFileOpenURL(fileURL as CFURL, .readPermission, 0, &audioFile),
            operation: "open downloaded audio"
        )
        guard let audioFile else {
            throw NativeQobuzError.invalidResponse("Downloaded audio could not be inspected")
        }
        defer { AudioFileClose(audioFile) }

        var fileType: AudioFileTypeID = 0
        var fileTypeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
        try requireSuccess(
            AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &fileTypeSize, &fileType),
            operation: "read downloaded audio container"
        )

        var stream = AudioStreamBasicDescription()
        var streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try requireSuccess(
            AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &streamSize, &stream),
            operation: "read downloaded audio codec"
        )

        let container: AudioContainerFormat = switch fileType {
        case kAudioFileFLACType: .flac
        case kAudioFileMP3Type: .mp3
        default:
            throw NativeQobuzError.invalidResponse(
                "Downloaded audio uses unsupported container \(fourCC(fileType))"
            )
        }
        let codec: AudioCodecFormat = switch stream.mFormatID {
        case kAudioFormatFLAC: .flac
        case kAudioFormatMPEGLayer3: .mp3
        default:
            throw NativeQobuzError.invalidResponse(
                "Downloaded audio uses unsupported codec \(fourCC(stream.mFormatID))"
            )
        }
        let bitDepth = sourceBitDepth(audioFile, fallback: stream.mBitsPerChannel)
        return AudioStreamProperties(
            container: container,
            codec: codec,
            bitDepth: bitDepth,
            samplingRate: stream.mSampleRate / 1_000
        )
    }

    private func sourceBitDepth(_ audioFile: AudioFileID, fallback: UInt32) -> Int? {
        var sourceDepth: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        if AudioFileGetProperty(audioFile, kAudioFilePropertySourceBitDepth, &size, &sourceDepth) == noErr,
           sourceDepth != 0 {
            return abs(Int(sourceDepth))
        }
        return fallback > 0 ? Int(fallback) : nil
    }

    private func requireSuccess(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NativeQobuzError.invalidResponse("Could not \(operation) (OSStatus \(status))")
        }
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        let printable = bytes.map { byte in
            byte >= 32 && byte <= 126 ? Character(UnicodeScalar(byte)) : "?"
        }
        return "'\(String(printable))'"
    }
}
