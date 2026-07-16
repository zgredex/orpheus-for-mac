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
            grouped[audioPath.parent, default: []].append((audioPath.lastComponent!, output.sha256))
        }
        var manifests: [URL] = []
        for folder in grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let destination = try folder.appending(QobuzChecksumManifest.filename)
            var entries: [String: String]
            do {
                entries = try QobuzChecksumManifest.load(at: destination, in: fileSystem)
            } catch {
                entries = [:]
                qobuzLog.warning(
                    "asset.checksum",
                    "Existing checksum manifest could not be read and will be rebuilt",
                    metadata: ["manifestPath": destination.rawValue],
                    error: error
                )
            }
            for entry in grouped[folder, default: []] { entries[entry.name] = entry.sha256 }
            try fileSystem.writeAtomically(QobuzChecksumManifest.encode(entries), to: destination)
            manifests.append(fileSystem.displayURL(for: destination))
        }
        return manifests
    }

    func expectedChecksum(for audioURL: URL, fileSystem: LibraryFileSystem) throws -> String? {
        let audioPath = try fileSystem.relativePath(for: audioURL)
        let manifest = try audioPath.parent.appending(QobuzChecksumManifest.filename)
        return try QobuzChecksumManifest.load(at: manifest, in: fileSystem)[audioPath.lastComponent!]
    }

    func provenance(for audioURL: URL, fileSystem: LibraryFileSystem) throws -> QobuzFileProvenance? {
        let audioPath = try fileSystem.relativePath(for: audioURL)
        return try provenanceManifest(in: audioPath.parent, fileSystem: fileSystem).files[audioPath.lastComponent!]
    }

    func record(
        _ provenance: QobuzFileProvenance,
        for audioURL: URL,
        fileSystem: LibraryFileSystem
    ) throws {
        let audioPath = try fileSystem.relativePath(for: audioURL)
        var manifest: QobuzProvenanceManifest
        do {
            manifest = try provenanceManifest(in: audioPath.parent, fileSystem: fileSystem)
        } catch {
            manifest = QobuzProvenanceManifest()
            qobuzLog.warning(
                "asset.provenance",
                "Existing provenance could not be read and will be rebuilt",
                metadata: [
                    "manifestPath": (try? provenancePath(in: audioPath.parent).rawValue) ?? audioPath.parent.rawValue
                ],
                error: error
            )
        }
        manifest.files[audioPath.lastComponent!] = provenance
        let path = try provenancePath(in: audioPath.parent)
        try fileSystem.writeAtomically(try QobuzProvenanceManifestIO.encode(manifest), to: path)
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

    func markLibraryManaged(_ audioURLs: [URL], fileSystem: LibraryFileSystem) throws {
        var visited = Set<LibraryRelativePath>()
        for audioURL in audioURLs {
            let path = try fileSystem.relativePath(for: audioURL)
            guard visited.insert(path).inserted,
                  let provenance = try provenance(for: audioURL, fileSystem: fileSystem),
                  !provenance.isLibraryManaged else { continue }
            try record(provenance.markingLibraryManaged(), for: audioURL, fileSystem: fileSystem)
        }
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
}
