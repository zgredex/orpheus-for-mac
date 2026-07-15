import Foundation

struct QobuzArchiveIntegrityEvaluation {
    let actualChecksum: String?
    let byteCount: Int64?
    let modificationDate: Date?
    let integrity: QobuzArchiveIntegrity
    let reusedChecksum: Bool
    let issueMessage: String?
}

struct QobuzArchiveIntegrityEvaluator {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func evaluate(
        audioURL: URL,
        relativePath: String,
        provenance: QobuzFileProvenance,
        manifestChecksum: String?,
        previous: QobuzArchiveTrack?,
        logMetadata: [String: String]
    ) -> QobuzArchiveIntegrityEvaluation {
        let metadataConflict = manifestChecksum.map {
            $0.caseInsensitiveCompare(provenance.sha256) != .orderedSame
        } ?? false
        guard fileManager.fileExists(atPath: audioURL.path) else {
            return QobuzArchiveIntegrityEvaluation(
                actualChecksum: nil,
                byteCount: nil,
                modificationDate: nil,
                integrity: .missing,
                reusedChecksum: false,
                issueMessage: nil
            )
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: audioURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value
            let modificationDate = attributes[.modificationDate] as? Date
            if !metadataConflict,
               let previous,
               canReuseIntegrity(
                   previous,
                   provenance: provenance,
                   byteCount: byteCount,
                   modificationDate: modificationDate
               ) {
                return QobuzArchiveIntegrityEvaluation(
                    actualChecksum: previous.actualSHA256,
                    byteCount: byteCount,
                    modificationDate: modificationDate,
                    integrity: previous.integrity,
                    reusedChecksum: true,
                    issueMessage: nil
                )
            }

            let actualChecksum = try MusicFileIntegrity.sha256(of: audioURL)
            let integrity: QobuzArchiveIntegrity
            if metadataConflict {
                integrity = .metadataConflict
            } else if actualChecksum.caseInsensitiveCompare(provenance.sha256) == .orderedSame {
                integrity = .verified
            } else {
                integrity = .checksumMismatch
            }
            return QobuzArchiveIntegrityEvaluation(
                actualChecksum: actualChecksum,
                byteCount: byteCount,
                modificationDate: modificationDate,
                integrity: integrity,
                reusedChecksum: false,
                issueMessage: nil
            )
        } catch {
            qobuzLog.error(
                "library.scan.track",
                "Library audio file could not be inspected",
                metadata: logMetadata.merging(["relativePath": relativePath]) { _, new in new },
                error: error
            )
            return QobuzArchiveIntegrityEvaluation(
                actualChecksum: nil,
                byteCount: nil,
                modificationDate: nil,
                integrity: .unreadable,
                reusedChecksum: false,
                issueMessage: error.localizedDescription
            )
        }
    }

    private func canReuseIntegrity(
        _ previous: QobuzArchiveTrack,
        provenance: QobuzFileProvenance,
        byteCount: Int64?,
        modificationDate: Date?
    ) -> Bool {
        previous.qobuzTrackID == provenance.qobuzTrackID
            && previous.qobuzAlbumID == provenance.qobuzAlbumID
            && previous.formatID == provenance.formatID
            && previous.expectedSHA256.caseInsensitiveCompare(provenance.sha256) == .orderedSame
            && previous.byteCount == byteCount
            && previous.modificationDate == modificationDate
            && previous.actualSHA256 != nil
            && previous.integrity != .unreadable
            && previous.integrity != .missing
            && previous.integrity != .metadataConflict
    }
}
