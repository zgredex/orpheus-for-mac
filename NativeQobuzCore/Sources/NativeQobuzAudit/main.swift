import Foundation
import NativeQobuzCore

@main
struct NativeQobuzAudit {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let credentials = QobuzCredentials(
            appID: try required("QOBUZ_APP_ID", environment),
            appSecret: try required("QOBUZ_APP_SECRET", environment),
            authToken: try required("QOBUZ_AUTH_TOKEN", environment)
        )
        let output = URL(
            fileURLWithPath: try required("QOBUZ_AUDIT_OUTPUT", environment),
            isDirectory: true
        )
        let albumID = QobuzID(environment["QOBUZ_TEST_ALBUM_ID"] ?? "je3x92urb9drs")
        let client = QobuzAPIClient(credentials: credentials)
        let album = try await client.album(id: albumID)
        guard let track = album.tracks.first else {
            throw NativeQobuzError.emptyCollection(album.displayTitle)
        }

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Auditing \(album.displayTitle) / \(track.displayTitle)")
        let resolved = QobuzResolvedTrack(
            track: track,
            album: album,
            collection: .album(id: album.id, title: album.displayTitle),
            position: 1,
            total: album.tracks.count
        )
        let shouldTag = environment["QOBUZ_AUDIT_TAG"] == "1"
        let artwork = shouldTag ? try await QobuzCollectionAssetWriter().artwork(for: album) : nil
        let validator = try FFmpegMediaValidator.bundled()
        for quality in [QobuzQuality.mp3, .hiRes] {
            let info = try await client.fileInfo(trackID: track.id, format: quality.maximumFormat)
            let destination = output.appendingPathComponent("raw-qobuz.\(info.fileExtension)")
            for try await event in URLSessionFileTransferClient().events(from: info.url, to: destination) {
                if case .completed(let url) = event {
                    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                    print("Saved \(url.path) (\(size?.int64Value ?? 0) bytes)")
                }
            }
            let media = try await validator.validate(destination)
            try QobuzDeliveryPolicy().validateCeiling(requestedMaximum: quality, delivered: info)
            _ = try QobuzDeliveryPolicy().validate(fileInfo: info, media: media)
            if shouldTag {
                try NativeAudioMetadataWriter().write(
                    metadata: QobuzAudioMetadata(item: resolved),
                    artwork: artwork,
                    to: destination
                )
                let taggedMedia = try await validator.validate(destination)
                _ = try QobuzDeliveryPolicy().validate(fileInfo: info, media: taggedMedia)
                print("Validated and tagged \(destination.path)")
            }
        }
    }

    private static func required(_ key: String, _ environment: [String: String]) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw NativeQobuzError.invalidResponse("Missing environment variable \(key).")
        }
        return value
    }
}
