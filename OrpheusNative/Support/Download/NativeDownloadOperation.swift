import Foundation
import NativeQobuzCore

/// The sole durable record for queue lifecycle, Activity presentation, transfer
/// telemetry, output discovery, warnings, and recovery position.
struct NativeDownloadOperation: Codable, Identifiable, Equatable, Sendable {
    let queueID: UUID
    var activityID: UUID?
    var status: NativeDownloadStatus
    var title = ""
    var quality: QobuzQuality?
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
    var outputURLs: [URL] = []
    var assetURLs: [URL] = []
    var checkpoint: QobuzDownloadCheckpoint?
    var checkpointUpdatedAt: Date?
    var activityCreatedAt: Date?

    var id: UUID { queueID }
    var latestOutputURL: URL? { outputURLs.last }

    init(
        queueID: UUID,
        activityID: UUID? = nil,
        status: NativeDownloadStatus = .ready,
        title: String = ""
    ) {
        self.queueID = queueID
        self.activityID = activityID
        self.status = status
        self.title = title
    }

    mutating func recordCheckpoint(_ value: QobuzDownloadCheckpoint) {
        checkpoint = value
        checkpointUpdatedAt = Date()
        if let outputURL = value.outputURL { recordOutput(outputURL) }
    }

    mutating func recordOutput(_ url: URL) {
        if !outputURLs.contains(url) { outputURLs.append(url) }
    }

    mutating func recordAsset(_ url: URL) {
        if !assetURLs.contains(url) { assetURLs.append(url) }
    }

    mutating func resetForRestart(
        title: String,
        quality: QobuzQuality?,
        audioFormat: QobuzAudioFormat?,
        phase: String
    ) {
        self.title = title
        self.quality = quality
        self.audioFormat = audioFormat
        self.phase = phase
        bytesPerSecond = nil
        errorMessage = nil
    }

    mutating func clearActivity() {
        activityID = nil
        status = .ready
        title = ""
        quality = nil
        audioFormat = nil
        phase = "Queued"
        currentTrack = nil
        progress = 0
        completedTracks = 0
        totalTracks = 0
        bytesWritten = nil
        totalBytes = nil
        bytesPerSecond = nil
        albumBytesWritten = nil
        checksum = nil
        notices = []
        warnings = []
        errorMessage = nil
        outputURLs = []
        assetURLs = []
        checkpoint = nil
        checkpointUpdatedAt = nil
        activityCreatedAt = nil
    }
}
