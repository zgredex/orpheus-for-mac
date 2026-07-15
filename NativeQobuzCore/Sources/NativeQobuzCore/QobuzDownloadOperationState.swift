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

final class QobuzDownloadOperationState: @unchecked Sendable {
    private(set) var downloaded = 0
    private(set) var skipped = 0
    private(set) var albumBytes: Int64 = 0
    var currentTrackBytes: Int64 = 0
    private(set) var outputs: [QobuzDownloadOutput] = []
    private(set) var verifiedOutputs: [QobuzVerifiedDownloadOutput] = []
    var reusableAudio: [String: URL]
    var artworkCache: [QobuzID: EmbeddedArtwork] = [:]
    var albumsWithoutArtwork = Set<QobuzID>()

    init(reusableAudio: [String: URL]) {
        self.reusableAudio = reusableAudio
    }

    func recordSkipped(
        item: QobuzResolvedTrack,
        destination: URL,
        checksum: String,
        bytes: Int64,
        fileInfo: QobuzFileInfo,
        reuseRegistry: QobuzAudioReuseRegistry,
        root: URL
    ) {
        albumBytes += bytes
        skipped += 1
        recordOutput(item: item, destination: destination, checksum: checksum)
        registerReusable(
            item: item,
            fileInfo: fileInfo,
            destination: destination,
            reuseRegistry: reuseRegistry,
            root: root
        )
    }

    func recordDownloaded(
        item: QobuzResolvedTrack,
        destination: URL,
        checksum: String,
        bytes: Int64,
        fileInfo: QobuzFileInfo,
        reuseRegistry: QobuzAudioReuseRegistry,
        root: URL
    ) {
        albumBytes += bytes
        currentTrackBytes = 0
        downloaded += 1
        recordOutput(item: item, destination: destination, checksum: checksum)
        registerReusable(
            item: item,
            fileInfo: fileInfo,
            destination: destination,
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
        fileInfo: QobuzFileInfo,
        destination: URL,
        reuseRegistry: QobuzAudioReuseRegistry,
        root: URL
    ) {
        let key = QobuzFileProvenance.reuseKey(item: item, fileInfo: fileInfo)
        reusableAudio[key] = destination
        reuseRegistry.store(destination, reuseKey: key, root: root)
    }
}
