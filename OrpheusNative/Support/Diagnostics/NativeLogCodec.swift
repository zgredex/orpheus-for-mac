import Foundation
import NativeQobuzCore

struct NativeLogCodec {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(
                text,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            ) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid diagnostic timestamp")
                )
            }
            return date
        }
    }

    func encodeLine(_ entry: QobuzLogEntry) throws -> Data {
        try encoder.encode(entry) + Data([0x0A])
    }

    func decodeLine(_ data: Data) throws -> QobuzLogEntry {
        try decoder.decode(QobuzLogEntry.self, from: data)
    }
}
