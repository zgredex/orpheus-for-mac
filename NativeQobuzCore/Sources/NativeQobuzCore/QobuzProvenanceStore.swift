import Foundation

struct QobuzProvenanceStore: Sendable {
    func reusableAudioIndex(fileSystem: LibraryFileSystem) throws -> [String: URL] {
        qobuzLog.debug(
            "asset.reuse",
            "Reusable audio index scan started",
            metadata: ["downloadRoot": fileSystem.rootURL.path]
        )
        let snapshot = try fileSystem.recursiveSnapshot()
        var result: [String: URL] = [:]
        for entry in snapshot.entries where entry.path.lastComponent == QobuzProvenanceManifestIO.filename {
            guard entry.metadata.kind == .regularFile else { continue }
            let manifest: QobuzProvenanceManifest
            do {
                manifest = try QobuzProvenanceManifestIO.load(from: entry.path, in: fileSystem)
            } catch {
                qobuzLog.warning(
                    "asset.reuse",
                    "Ignored unreadable provenance manifest",
                    metadata: ["manifestPath": entry.path.rawValue],
                    error: error
                )
                continue
            }
            for (filename, provenance) in manifest.files where QobuzPathSafety.isSafeLeafName(filename) {
                let audioPath = try entry.path.parent.appending(filename)
                guard try fileSystem.metadata(at: audioPath)?.kind == .regularFile else { continue }
                result[provenance.reuseKey] = fileSystem.displayURL(for: audioPath)
            }
        }
        qobuzLog.debug(
            "asset.reuse",
            "Reusable audio index scan completed",
            metadata: ["downloadRoot": fileSystem.rootURL.path, "candidateCount": String(result.count)]
        )
        return result
    }

    func writeChecksumManifests(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)],
        fileSystem: LibraryFileSystem
    ) throws -> [URL] {
        var grouped: [LibraryRelativePath: [(name: String, sha256: String)]] = [:]
        for output in outputs {
            let audioPath = try fileSystem.relativePath(for: output.audioURL)
            grouped[audioPath.parent, default: []].append((try audioLeafName(audioPath), output.sha256))
        }
        var updates: [(path: LibraryRelativePath, data: Data)] = []
        for folder in grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let destination = try folder.appending(QobuzChecksumManifest.filename)
            var entries = try QobuzChecksumManifest.load(at: destination, in: fileSystem)
            for entry in grouped[folder, default: []] { entries[entry.name] = entry.sha256 }
            updates.append((destination, QobuzChecksumManifest.encode(entries)))
        }
        var manifests: [URL] = []
        for update in updates {
            try fileSystem.writeAtomically(update.data, to: update.path)
            manifests.append(fileSystem.displayURL(for: update.path))
        }
        return manifests
    }

    func expectedChecksum(for audioURL: URL, fileSystem: LibraryFileSystem) throws -> String? {
        let audioPath = try fileSystem.relativePath(for: audioURL)
        let manifest = try audioPath.parent.appending(QobuzChecksumManifest.filename)
        return try QobuzChecksumManifest.load(at: manifest, in: fileSystem)[audioLeafName(audioPath)]
    }

    func provenance(for audioURL: URL, fileSystem: LibraryFileSystem) throws -> QobuzFileProvenance? {
        let audioPath = try fileSystem.relativePath(for: audioURL)
        return try provenanceManifest(in: audioPath.parent, fileSystem: fileSystem).files[audioLeafName(audioPath)]
    }

    func record(
        _ provenance: QobuzFileProvenance,
        for audioURL: URL,
        fileSystem: LibraryFileSystem
    ) throws {
        let mutation = try mutation(
            recording: provenance,
            for: audioURL,
            fileSystem: fileSystem
        )
        guard case .data(let data) = mutation.finalState else {
            throw NativeQobuzError.invalidResponse("The provenance update was not a data mutation.")
        }
        try fileSystem.writeAtomically(data, to: mutation.path)
        let audioPath = try fileSystem.relativePath(for: audioURL)
        logRecorded(provenance, audioPath: audioPath)
    }

    func mutation(
        recording provenance: QobuzFileProvenance,
        for audioURL: URL,
        fileSystem: LibraryFileSystem
    ) throws -> LibraryFileTransactionMutation {
        let audioPath = try fileSystem.relativePath(for: audioURL)
        var manifest = try provenanceManifest(in: audioPath.parent, fileSystem: fileSystem)
        manifest.files[try audioLeafName(audioPath)] = provenance
        let path = try provenancePath(in: audioPath.parent)
        return try LibraryFileTransactionMutation.capture(
            path: path,
            finalState: .data(try QobuzProvenanceManifestIO.encode(manifest)),
            in: fileSystem
        )
    }

    func mutationsMarkingLibraryManaged(
        _ audioURLs: [URL],
        fileSystem: LibraryFileSystem
    ) throws -> [LibraryFileTransactionMutation] {
        var grouped: [LibraryRelativePath: Set<String>] = [:]
        for audioURL in audioURLs {
            let audioPath = try fileSystem.relativePath(for: audioURL)
            grouped[audioPath.parent, default: []].insert(try audioLeafName(audioPath))
        }
        return try grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { folder in
            var manifest = try provenanceManifest(in: folder, fileSystem: fileSystem)
            var changed = false
            for filename in grouped[folder, default: []].sorted() {
                guard let provenance = manifest.files[filename] else {
                    throw NativeQobuzError.invalidResponse(
                        "Downloaded audio is missing provenance and cannot enter the Library."
                    )
                }
                guard !provenance.isLibraryManaged else { continue }
                manifest.files[filename] = provenance.markingLibraryManaged()
                changed = true
            }
            guard changed else { return nil }
            let path = try provenancePath(in: folder)
            return try LibraryFileTransactionMutation.capture(
                path: path,
                finalState: .data(try QobuzProvenanceManifestIO.encode(manifest)),
                in: fileSystem
            )
        }
    }

    func validateLibraryManaged(
        _ audioURLs: [URL],
        fileSystem: LibraryFileSystem
    ) throws {
        for audioURL in audioURLs {
            guard try provenance(for: audioURL, fileSystem: fileSystem)?.isLibraryManaged == true else {
                throw NativeQobuzError.invalidResponse(
                    "Library membership was published without managed audio provenance."
                )
            }
        }
    }

    private func logRecorded(
        _ provenance: QobuzFileProvenance,
        audioPath: LibraryRelativePath
    ) {
        qobuzLog.debug(
            "asset.provenance",
            "Audio provenance recorded",
            metadata: [
                "audioPath": audioPath.rawValue,
                "trackID": provenance.qobuzTrackID,
                "albumID": provenance.qobuzAlbumID,
                "formatID": String(provenance.formatID),
                "sha256": provenance.sha256
            ]
        )
    }

    private func provenanceManifest(
        in folder: LibraryRelativePath,
        fileSystem: LibraryFileSystem
    ) throws -> QobuzProvenanceManifest {
        do {
            return try QobuzProvenanceManifestIO.load(from: provenancePath(in: folder), in: fileSystem)
        } catch let error as NativeQobuzError {
            throw error
        } catch {
            throw NativeQobuzError.invalidResponse("Could not read download provenance: \(error.localizedDescription)")
        }
    }

    private func provenancePath(in folder: LibraryRelativePath) throws -> LibraryRelativePath {
        try folder.appending(QobuzProvenanceManifestIO.filename)
    }

    private func audioLeafName(_ path: LibraryRelativePath) throws -> String {
        guard let name = path.lastComponent else {
            throw LibraryFileSystemError.unsafePath(path.rawValue)
        }
        return name
    }
}
