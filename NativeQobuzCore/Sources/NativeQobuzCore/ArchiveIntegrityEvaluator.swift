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
    func evaluate(
        audioPath: LibraryRelativePath,
        fileSystem: LibraryFileSystem,
        provenance: QobuzFileProvenance,
        manifestChecksum: String?,
        previous: QobuzArchiveTrack?,
        logMetadata: [String: String]
    ) -> QobuzArchiveIntegrityEvaluation {
        let metadataConflict = manifestChecksum.map {
            $0.caseInsensitiveCompare(provenance.sha256) != .orderedSame
        } ?? false
        let relativePath = audioPath.rawValue
        let fileMetadata: LibraryFileMetadata
        do {
            guard let metadata = try fileSystem.metadata(at: audioPath) else {
                return QobuzArchiveIntegrityEvaluation(
                    actualChecksum: nil,
                    byteCount: nil,
                    modificationDate: nil,
                    integrity: .missing,
                    reusedChecksum: false,
                    issueMessage: nil
                )
            }
            fileMetadata = metadata
        } catch {
            return unreadable(
                error,
                relativePath: relativePath,
                logMetadata: logMetadata
            )
        }

        do {
            guard fileMetadata.kind == .regularFile else {
                if fileMetadata.kind == .symbolicLink {
                    throw LibraryFileSystemError.symbolicLink(relativePath)
                }
                if fileMetadata.kind == .hardLink {
                    throw LibraryFileSystemError.hardLink(relativePath)
                }
                throw LibraryFileSystemError.notRegularFile(relativePath)
            }
            let byteCount = fileMetadata.byteCount
            let modificationDate = fileMetadata.modificationDate
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

            let actualChecksum = try MusicFileIntegrity.sha256(of: audioPath, in: fileSystem)
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
            return unreadable(error, relativePath: relativePath, logMetadata: logMetadata)
        }
    }

    private func unreadable(
        _ error: Error,
        relativePath: String,
        logMetadata: [String: String]
    ) -> QobuzArchiveIntegrityEvaluation {
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
