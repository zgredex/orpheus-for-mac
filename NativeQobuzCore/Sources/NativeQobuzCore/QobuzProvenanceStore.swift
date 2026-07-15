import Foundation

struct QobuzProvenanceStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let atomicWriter: QobuzAtomicFileWriter

    init(fileManager: FileManager, atomicWriter: QobuzAtomicFileWriter) {
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
    }

    func reusableAudioIndex(root: URL) throws -> [String: URL] {
        qobuzLog.debug("asset.reuse", "Reusable audio index scan started", metadata: ["downloadRoot": root.path])
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [:] }
        var result: [String: URL] = [:]
        while let manifestURL = enumerator.nextObject() as? URL {
            guard manifestURL.lastPathComponent == QobuzProvenanceManifestIO.filename else { continue }
            let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                qobuzLog.warning("asset.reuse", "Ignored unsafe provenance manifest", metadata: ["manifestPath": manifestURL.path])
                continue
            }
            let manifest: QobuzProvenanceManifest
            do {
                manifest = try QobuzProvenanceManifestIO.load(from: manifestURL, fileManager: fileManager)
            } catch {
                qobuzLog.warning(
                    "asset.reuse",
                    "Ignored unreadable provenance manifest",
                    metadata: ["manifestPath": manifestURL.path],
                    error: error
                )
                continue
            }
            let folder = manifestURL.deletingLastPathComponent()
            for (filename, provenance) in manifest.files where QobuzPathSafety.isSafeLeafName(filename) {
                let audioURL = folder.appendingPathComponent(filename)
                let audioValues = try? audioURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard audioValues?.isRegularFile == true, audioValues?.isSymbolicLink != true else { continue }
                result[provenance.reuseKey] = audioURL
            }
        }
        qobuzLog.debug(
            "asset.reuse",
            "Reusable audio index scan completed",
            metadata: ["downloadRoot": root.path, "candidateCount": String(result.count)]
        )
        return result
    }

    func writeChecksumManifests(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL, sha256: String)]
    ) throws -> [URL] {
        var grouped: [URL: [(name: String, sha256: String)]] = [:]
        for output in outputs {
            grouped[output.audioURL.deletingLastPathComponent(), default: []].append(
                (output.audioURL.lastPathComponent, output.sha256)
            )
        }
        var manifests: [URL] = []
        for folder in grouped.keys.sorted(by: { $0.path < $1.path }) {
            let destination = folder.appendingPathComponent(QobuzChecksumManifest.filename)
            var entries: [String: String]
            do {
                entries = try QobuzChecksumManifest.load(at: destination, fileManager: fileManager)
            } catch {
                entries = [:]
                qobuzLog.warning(
                    "asset.checksum",
                    "Existing checksum manifest could not be read and will be rebuilt",
                    metadata: ["manifestPath": destination.path],
                    error: error
                )
            }
            for entry in grouped[folder, default: []] { entries[entry.name] = entry.sha256 }
            try atomicWriter.write(QobuzChecksumManifest.encode(entries), to: destination)
            manifests.append(destination)
        }
        return manifests
    }

    func expectedChecksum(for audioURL: URL) throws -> String? {
        let manifest = audioURL.deletingLastPathComponent().appendingPathComponent(QobuzChecksumManifest.filename)
        return try QobuzChecksumManifest.load(at: manifest, fileManager: fileManager)[audioURL.lastPathComponent]
    }

    func provenance(for audioURL: URL) throws -> QobuzFileProvenance? {
        try provenanceManifest(in: audioURL.deletingLastPathComponent()).files[audioURL.lastPathComponent]
    }

    func record(_ provenance: QobuzFileProvenance, for audioURL: URL) throws {
        let folder = audioURL.deletingLastPathComponent()
        var manifest: QobuzProvenanceManifest
        do {
            manifest = try provenanceManifest(in: folder)
        } catch {
            manifest = QobuzProvenanceManifest()
            qobuzLog.warning(
                "asset.provenance",
                "Existing provenance could not be read and will be rebuilt",
                metadata: ["manifestPath": provenanceURL(in: folder).path],
                error: error
            )
        }
        manifest.files[audioURL.lastPathComponent] = provenance
        try atomicWriter.write(try QobuzProvenanceManifestIO.encode(manifest), to: provenanceURL(in: folder))
        qobuzLog.debug(
            "asset.provenance",
            "Audio provenance recorded",
            metadata: [
                "audioPath": audioURL.path,
                "trackID": provenance.qobuzTrackID,
                "albumID": provenance.qobuzAlbumID,
                "formatID": String(provenance.formatID),
                "sha256": provenance.sha256
            ]
        )
    }

    func markLibraryManaged(_ audioURLs: [URL]) throws {
        var visited = Set<URL>()
        for audioURL in audioURLs where visited.insert(audioURL.standardizedFileURL).inserted {
            guard let provenance = try provenance(for: audioURL), !provenance.isLibraryManaged else { continue }
            try record(provenance.markingLibraryManaged(), for: audioURL)
        }
    }

    private func provenanceManifest(in folder: URL) throws -> QobuzProvenanceManifest {
        do {
            return try QobuzProvenanceManifestIO.load(in: folder, fileManager: fileManager)
        } catch let error as NativeQobuzError {
            throw error
        } catch {
            throw NativeQobuzError.invalidResponse("Could not read download provenance: \(error.localizedDescription)")
        }
    }

    private func provenanceURL(in folder: URL) -> URL {
        folder.appendingPathComponent(QobuzProvenanceManifestIO.filename)
    }
}
