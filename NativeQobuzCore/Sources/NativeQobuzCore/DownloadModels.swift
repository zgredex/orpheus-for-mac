import Foundation

public struct QobuzDownloadProgress: Equatable, Sendable {
    public let completedTracks: Int
    public let totalTracks: Int
    public let currentTrackFraction: Double?
    public let overallFraction: Double
    public let bytesWritten: Int64?
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?
    public let albumBytesWritten: Int64?

    public init(
        completedTracks: Int,
        totalTracks: Int,
        currentTrackFraction: Double?,
        overallFraction: Double,
        bytesWritten: Int64?,
        totalBytes: Int64?,
        bytesPerSecond: Double?,
        albumBytesWritten: Int64? = nil
    ) {
        self.completedTracks = completedTracks
        self.totalTracks = totalTracks
        self.currentTrackFraction = currentTrackFraction
        self.overallFraction = min(max(overallFraction.isFinite ? overallFraction : 0, 0), 1)
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.albumBytesWritten = albumBytesWritten
    }

    static func completed(completed: Int, total: Int, albumBytes: Int64) -> QobuzDownloadProgress {
        QobuzDownloadProgress(
            completedTracks: completed,
            totalTracks: total,
            currentTrackFraction: 1,
            overallFraction: Double(completed) / Double(max(total, 1)),
            bytesWritten: nil,
            totalBytes: nil,
            bytesPerSecond: nil,
            albumBytesWritten: albumBytes
        )
    }
}

public enum QobuzDownloadEvent: Equatable, Sendable {
    case resolving(QobuzRequest)
    case planReady(title: String, trackCount: Int)
    case trackStarted(track: QobuzResolvedTrack, destination: URL, format: QobuzAudioFormat)
    case progress(QobuzDownloadProgress)
    case validating(track: QobuzResolvedTrack)
    case tagging(track: QobuzResolvedTrack)
    case integrityVerified(track: QobuzResolvedTrack, sha256: String)
    case assetCreated(URL)
    case notice(String)
    case warning(String)
    case trackCompleted(track: QobuzResolvedTrack, destination: URL)
    case trackSkipped(track: QobuzResolvedTrack, destination: URL)
    case completed(title: String, downloaded: Int, skipped: Int)
}

public enum QobuzDownloadArtifacts {
    public static func processingURL(for destination: URL, formatID: Int) -> URL {
        let filename = QobuzFilenameComponent.make(
            prefix: ".",
            stem: destination.deletingPathExtension().lastPathComponent,
            suffix: ".qobuz-\(formatID).processing",
            pathExtension: destination.pathExtension,
            maximumBytes: QobuzFilenameComponent.maximumBytes - ".partial".utf8.count
        )
        return destination.deletingLastPathComponent().appendingPathComponent(filename)
    }

    public static func partialURL(for destination: URL, formatID: Int) -> URL {
        processingURL(for: destination, formatID: formatID).appendingPathExtension("partial")
    }
}

typealias QobuzDownloadContinuation = AsyncThrowingStream<QobuzDownloadEvent, Error>.Continuation

struct QobuzDownloadConfiguration: Sendable {
    let request: QobuzRequest
    let requestedFormat: QobuzAudioFormat
    let requestedMaximum: QobuzQuality?
    let downloadRoot: URL
    let repairTarget: QobuzArchiveTrack?
    let includedTrackIDs: Set<QobuzID>?

    var logMetadata: [String: String] {
        [
            "downloadOperationID": UUID().uuidString,
            "requestKind": request.kindName,
            "qobuzID": request.id.rawValue,
            "qualityPolicy": requestedMaximum?.rawValue ?? "exact-archive-repair",
            "requestedFormatID": String(requestedFormat.formatID),
            "downloadRoot": downloadRoot.path,
            "repair": String(repairTarget != nil),
            "selectedTrackCount": includedTrackIDs.map { String($0.count) } ?? "all"
        ]
    }
}
