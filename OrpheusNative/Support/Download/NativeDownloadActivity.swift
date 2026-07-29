import Foundation
import NativeQobuzCore

/// Read-only UI projection of an authoritative `NativeDownloadOperation`.
/// It is never encoded or mutated independently.
struct NativeDownloadActivity: Identifiable, Equatable {
    let operation: NativeDownloadOperation
    let id: UUID

    init(operation: NativeDownloadOperation) {
        self.operation = operation
        id = operation.activityID ?? operation.queueID
    }
    var queueID: UUID { operation.queueID }
    var title: String { operation.title }
    var quality: QobuzQuality? { operation.quality }
    var audioFormat: QobuzAudioFormat? { operation.audioFormat }
    var phase: String { operation.phase }
    var currentTrack: String? { operation.currentTrack }
    var progress: Double { operation.progress }
    var completedTracks: Int { operation.completedTracks }
    var totalTracks: Int { operation.totalTracks }
    var bytesWritten: Int64? { operation.bytesWritten }
    var totalBytes: Int64? { operation.totalBytes }
    var bytesPerSecond: Double? { operation.bytesPerSecond }
    var albumBytesWritten: Int64? { operation.albumBytesWritten }
    var checksum: String? { operation.checksum }
    var notices: [String] { operation.notices }
    var warnings: [String] { operation.warnings }
    var errorMessage: String? { operation.errorMessage }
    var outputURL: URL? { operation.latestOutputURL }
    var checkpoint: QobuzDownloadCheckpoint? { operation.checkpoint }
    var resumablePartial: NativePartialDownload? { operation.resumablePartial }
    var informationalNotices: [String] { notices }
}

struct NativePartialDownload: Codable, Equatable, Sendable {
    let url: URL
    let bytes: Int64
}
