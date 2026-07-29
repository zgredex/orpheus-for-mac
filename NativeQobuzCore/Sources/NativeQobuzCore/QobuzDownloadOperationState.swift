import Foundation

struct QobuzDownloadOutput: Sendable {
    let item: QobuzResolvedTrack
    let audioURL: URL
}

struct QobuzVerifiedDownloadOutput: Sendable {
    let item: QobuzResolvedTrack
    let audioURL: URL
    let sha256: String
}

struct QobuzCompletedTrackRecord: Sendable {
    let item: QobuzResolvedTrack
    let destination: URL
    let checksum: String
    let bytes: Int64
    let delivery: QobuzValidatedAudioDelivery
}

enum QobuzTrackCompletionDisposition: Sendable {
    case downloaded
    case reused
}

final class QobuzDownloadOperationState: @unchecked Sendable {
    private(set) var downloaded = 0
    private(set) var skipped = 0
    private(set) var albumBytes: Int64 = 0
    var currentTrackBytes: Int64 = 0
    private(set) var outputs: [QobuzDownloadOutput] = []
    private(set) var verifiedOutputs: [QobuzVerifiedDownloadOutput] = []
    var reusableAudio: [String: URL]
    let artworkCache = QobuzArtworkMemoryCache()

    init(reusableAudio: [String: URL]) {
        self.reusableAudio = reusableAudio
    }

    func record(
        _ completed: QobuzCompletedTrackRecord,
        disposition: QobuzTrackCompletionDisposition,
        reuseRegistry: QobuzAudioReuseRegistry,
        root: URL
    ) {
        albumBytes += completed.bytes
        switch disposition {
        case .downloaded:
            currentTrackBytes = 0
            downloaded += 1
        case .reused:
            skipped += 1
        }
        recordOutput(
            item: completed.item,
            destination: completed.destination,
            checksum: completed.checksum
        )
        registerReusable(
            item: completed.item,
            delivery: completed.delivery,
            destination: completed.destination,
            reuseRegistry: reuseRegistry,
            root: root
        )
    }

    var outputTuples: [(item: QobuzResolvedTrack, audioURL: URL)] {
        outputs.map { ($0.item, $0.audioURL) }
    }

    var verifiedOutputTuples: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)] {
        verifiedOutputs.map { ($0.item, $0.audioURL, $0.sha256) }
    }

    private func recordOutput(item: QobuzResolvedTrack, destination: URL, checksum: String) {
        outputs.append(QobuzDownloadOutput(item: item, audioURL: destination))
        verifiedOutputs.append(QobuzVerifiedDownloadOutput(item: item, audioURL: destination, sha256: checksum))
    }

    private func registerReusable(
        item: QobuzResolvedTrack,
        delivery: QobuzValidatedAudioDelivery,
        destination: URL,
        reuseRegistry: QobuzAudioReuseRegistry,
        root: URL
    ) {
        let key = QobuzFileProvenance.reuseKey(item: item, delivery: delivery)
        reusableAudio[key] = destination
        reuseRegistry.store(destination, reuseKey: key, root: root)
    }
}
