import Foundation
import NativeQobuzCore

struct NativeDownloadActivity: Codable, Identifiable, Equatable {
    let id: UUID
    let queueID: UUID
    var title: String
    /// User maximum for normal downloads. Repairs instead use `audioFormat`.
    var quality: QobuzQuality?
    /// Exact archived format requested by a repair.
    var audioFormat: QobuzAudioFormat?
    var phase = "Queued"
    var currentTrack: String?
    var progress = 0.0
    var completedTracks = 0
    var totalTracks = 0
    var bytesWritten: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var albumBytesWritten: Int64?
    var checksum: String?
    var notices: [String] = []
    var warnings: [String] = []
    var errorMessage: String?
    var outputURL: URL?

    var informationalNotices: [String] { notices }

    init(
        id: UUID,
        queueID: UUID,
        title: String,
        quality: QobuzQuality? = nil,
        audioFormat: QobuzAudioFormat? = nil
    ) {
        self.id = id
        self.queueID = queueID
        self.title = title
        self.quality = quality
        self.audioFormat = audioFormat
    }
}

struct NativePartialDownload: Equatable {
    let url: URL
    let bytes: Int64
}
