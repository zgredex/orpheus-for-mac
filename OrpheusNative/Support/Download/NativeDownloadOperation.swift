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
    var downloadRootPath: String?
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
    var resumablePartial: NativePartialDownload?

    var id: UUID { queueID }
    var latestOutputURL: URL? { outputURLs.last }
    var downloadRootURL: URL? {
        downloadRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
    }
    var retainsWritableRecoveryContext: Bool {
        activityID != nil && (status.isActive || status.canResume || status.canRetry)
    }
    var hasLibraryIndexReceipt: Bool {
        guard status != .completed, !outputURLs.isEmpty else { return false }
        return checkpoint?.phase == .indexingLibrary || checkpoint?.phase == .complete
    }

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
        downloadRoot: URL,
        phase: String,
        resumablePartial: NativePartialDownload?
    ) {
        let recoveryCheckpoint = resumablePartial == nil ? nil : checkpoint
        let recoveryCheckpointDate = resumablePartial == nil ? nil : checkpointUpdatedAt
        let recoveryOutput = resumablePartial == nil ? nil : latestOutputURL
        self.title = title
        self.quality = quality
        self.audioFormat = audioFormat
        downloadRootPath = downloadRoot.standardizedFileURL.path
        self.phase = phase
        resetAttemptTelemetry()
        outputURLs = recoveryOutput.map { [$0] } ?? []
        checkpoint = recoveryCheckpoint
        checkpointUpdatedAt = recoveryCheckpointDate
        self.resumablePartial = resumablePartial
    }

    private mutating func resetAttemptTelemetry() {
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
        resumablePartial = nil
    }

    mutating func clearActivity() {
        activityID = nil
        status = .ready
        title = ""
        quality = nil
        audioFormat = nil
        downloadRootPath = nil
        phase = "Queued"
        resetAttemptTelemetry()
        activityCreatedAt = nil
    }
}
