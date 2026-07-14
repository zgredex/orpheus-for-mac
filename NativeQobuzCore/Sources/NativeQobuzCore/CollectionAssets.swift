import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct QobuzAssetResponse: Sendable {
    public let data: Data
    public let mimeType: String?

    public init(data: Data, mimeType: String? = nil) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Layer 3: stable facts about the exact downloaded file. This record is the
/// archive source of truth and intentionally excludes refreshable catalog/UI
/// metadata and portable audio tags.
public struct QobuzFileProvenance: Codable, Equatable, Sendable {
    public let qobuzTrackID: String
    public let qobuzAlbumID: String
    public let formatID: Int
    public let bitDepth: Int?
    public let samplingRate: Double?
    public let sha256: String
    public let archiveKind: QobuzArchiveKind
    public let isLibraryManaged: Bool

    public init(
        item: QobuzResolvedTrack,
        fileInfo: QobuzFileInfo,
        sha256: String,
        archiveKind: QobuzArchiveKind? = nil,
        isLibraryManaged: Bool = false
    ) {
        qobuzTrackID = item.track.id.rawValue
        qobuzAlbumID = item.album.id.rawValue
        formatID = fileInfo.formatID
        bitDepth = fileInfo.bitDepth
        samplingRate = fileInfo.samplingRate
        self.sha256 = sha256
        self.archiveKind = archiveKind ?? item.collection.archiveKind
        self.isLibraryManaged = isLibraryManaged
    }

    private enum CodingKeys: String, CodingKey {
        case qobuzTrackID
        case qobuzAlbumID
        case formatID
        case bitDepth
        case samplingRate
        case sha256
        case archiveKind
        case isLibraryManaged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qobuzTrackID = try container.decode(String.self, forKey: .qobuzTrackID)
        qobuzAlbumID = try container.decode(String.self, forKey: .qobuzAlbumID)
        formatID = try container.decode(Int.self, forKey: .formatID)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        samplingRate = try container.decodeIfPresent(Double.self, forKey: .samplingRate)
        sha256 = try container.decode(String.self, forKey: .sha256)
        archiveKind = try container.decodeIfPresent(QobuzArchiveKind.self, forKey: .archiveKind)
            ?? .unclassified
        isLibraryManaged = try container.decodeIfPresent(Bool.self, forKey: .isLibraryManaged) ?? false
    }

    public func belongs(to item: QobuzResolvedTrack) -> Bool {
        qobuzTrackID == item.track.id.rawValue && qobuzAlbumID == item.album.id.rawValue
    }

    public func matches(item: QobuzResolvedTrack, fileInfo: QobuzFileInfo) -> Bool {
        belongs(to: item)
            && formatID == fileInfo.formatID
            && bitDepth == fileInfo.bitDepth
            && ratesMatch(samplingRate, fileInfo.samplingRate)
    }

    public var reuseKey: String {
        Self.reuseKey(
            trackID: qobuzTrackID,
            albumID: qobuzAlbumID,
            formatID: formatID,
            bitDepth: bitDepth,
            samplingRate: samplingRate
        )
    }

    public static func reuseKey(item: QobuzResolvedTrack, fileInfo: QobuzFileInfo) -> String {
        reuseKey(
            trackID: item.track.id.rawValue,
            albumID: item.album.id.rawValue,
            formatID: fileInfo.formatID,
            bitDepth: fileInfo.bitDepth,
            samplingRate: fileInfo.samplingRate
        )
    }

    private static func reuseKey(
        trackID: String,
        albumID: String,
        formatID: Int,
        bitDepth: Int?,
        samplingRate: Double?
    ) -> String {
        let depth = bitDepth.map { String($0) } ?? "-"
        let rate = samplingRate.map { String($0) } ?? "-"
        return "\(trackID)|\(albumID)|\(formatID)|\(depth)|\(rate)"
    }

    private func ratesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) < 0.001
        default: false
        }
    }

    fileprivate func markingLibraryManaged() -> QobuzFileProvenance {
        QobuzFileProvenance(
            qobuzTrackID: qobuzTrackID,
            qobuzAlbumID: qobuzAlbumID,
            formatID: formatID,
            bitDepth: bitDepth,
            samplingRate: samplingRate,
            sha256: sha256,
            archiveKind: archiveKind,
            isLibraryManaged: true
        )
    }

    private init(
        qobuzTrackID: String,
        qobuzAlbumID: String,
        formatID: Int,
        bitDepth: Int?,
        samplingRate: Double?,
        sha256: String,
        archiveKind: QobuzArchiveKind,
        isLibraryManaged: Bool
    ) {
        self.qobuzTrackID = qobuzTrackID
        self.qobuzAlbumID = qobuzAlbumID
        self.formatID = formatID
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.sha256 = sha256
        self.archiveKind = archiveKind
        self.isLibraryManaged = isLibraryManaged
    }
}

public protocol QobuzAssetFetching: Sendable {
    func fetch(_ url: URL) async throws -> QobuzAssetResponse
}

public struct URLSessionQobuzAssetFetcher: QobuzAssetFetching, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> QobuzAssetResponse {
        let assetID = UUID().uuidString
        let started = Date()
        let metadata = ["assetRequestID": assetID, "host": url.host ?? "unknown", "path": url.path]
        qobuzLog.info("asset.network", "Asset request started", metadata: metadata)
        do {
            let (data, response) = try await session.data(from: url)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                qobuzLog.error(
                    "asset.network",
                    "Asset request returned an HTTP failure",
                    metadata: metadata.merging(["status": String(response.statusCode)]) { _, new in new }
                )
                throw NativeQobuzError.http(response.statusCode, "Asset request failed")
            }
            guard !data.isEmpty else {
                throw NativeQobuzError.invalidResponse("Qobuz returned an empty asset")
            }
            qobuzLog.info(
                "asset.network",
                "Asset request completed",
                metadata: metadata.merging([
                    "responseBytes": String(data.count),
                    "mimeType": response.mimeType ?? "unknown",
                    "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
                ]) { _, new in new }
            )
            return QobuzAssetResponse(data: data, mimeType: response.mimeType)
        } catch let error as NativeQobuzError {
            qobuzLog.error("asset.network", "Asset request failed", metadata: metadata, error: error)
            throw error
        } catch is CancellationError {
            qobuzLog.notice("asset.network", "Asset request cancelled", metadata: metadata)
            throw NativeQobuzError.cancelled
        } catch {
            qobuzLog.error("asset.network", "Asset request failed", metadata: metadata, error: error)
            throw NativeQobuzError.networkFailure(error)
        }
    }
}

public struct QobuzCollectionAssetWriter: @unchecked Sendable {
    private struct ProvenanceManifest: Codable {
        var version = 1
        var files: [String: QobuzFileProvenance] = [:]
    }

    private let fetcher: any QobuzAssetFetching
    private let fileManager: FileManager

    public init(fetcher: any QobuzAssetFetching = URLSessionQobuzAssetFetcher(), fileManager: FileManager = .default) {
        self.fetcher = fetcher
        self.fileManager = fileManager
    }

    public func artwork(for album: QobuzAlbum) async throws -> EmbeddedArtwork? {
        guard let url = album.originalArtworkURL else { return nil }
        let response = try await fetcher.fetch(url)
        return EmbeddedArtwork.inspecting(data: response.data, mimeType: response.mimeType)
    }

    public func saveExternalArtwork(_ artwork: EmbeddedArtwork, for item: QobuzResolvedTrack, audioURL: URL) throws -> URL? {
        guard item.collection.usesAlbumFolders else { return nil }
        let destination = audioURL.deletingLastPathComponent().appendingPathComponent("cover.jpg")
        if fileManager.fileExists(atPath: destination.path) { return destination }
        try writeAtomically(artwork.data, to: destination)
        return destination
    }

    public func downloadBooklets(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)]
    ) async throws -> [URL] {
        var visited = Set<QobuzID>()
        var created: [URL] = []
        for output in outputs where output.item.collection.usesAlbumFolders {
            try Task.checkCancellation()
            let album = output.item.album
            guard visited.insert(album.id).inserted, let source = album.bookletURL else { continue }
            let destination = output.audioURL.deletingLastPathComponent().appendingPathComponent("Booklet.pdf")
            if fileManager.fileExists(atPath: destination.path) {
                created.append(destination)
                continue
            }
            let response = try await fetcher.fetch(source)
            guard response.data.starts(with: Data("%PDF-".utf8)) else {
                throw NativeQobuzError.invalidResponse("Qobuz booklet is not a PDF")
            }
            try writeAtomically(response.data, to: destination)
            created.append(destination)
        }
        return created
    }

    public func writeAlbumDescriptions(
        for outputs: [(item: QobuzResolvedTrack, audioURL: URL)]
    ) throws -> [URL] {
        var visited = Set<QobuzID>()
        var created: [URL] = []
        for output in outputs where output.item.collection.writesAlbumCollectionAssets {
            let album = output.item.album
            guard visited.insert(album.id).inserted,
                  let description = album.albumDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else { continue }
            let destination = output.audioURL.deletingLastPathComponent().appendingPathComponent("description.txt")
            try writeAtomically(Data(description.utf8), to: destination)
            created.append(destination)
        }
        return created
    }

    public func writePlaylist(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        downloadRoot: URL
    ) throws -> URL? {
        guard case .playlist(let id) = plan.request, !outputs.isEmpty else { return nil }
        let folder = playlistFolder(title: plan.title, id: id, root: downloadRoot)
        let name = StandardQobuzOutputPlanner().sanitize(plan.title)
        let destination = folder.appendingPathComponent("\(name).m3u")
        var lines = ["#EXTM3U"]
        for output in outputs {
            let duration = output.item.track.duration ?? -1
            let artist = output.item.track.performer?.name ?? output.item.album.artist.name
            lines.append("#EXTINF:\(duration), \(artist) - \(output.item.track.displayTitle)")
            lines.append(try portableRelativePath(from: folder, to: output.audioURL, root: downloadRoot))
            lines.append("")
        }
        try writeAtomically(Data(lines.joined(separator: "\n").utf8), to: destination)
        return destination
    }

    public func writePlaylistMetadata(plan: QobuzDownloadPlan, downloadRoot: URL) async throws -> [URL] {
        guard case .playlist(let id) = plan.request,
              case .playlist(let playlist)? = plan.source else { return [] }
        let folder = playlistFolder(title: plan.title, id: id, root: downloadRoot)
        var created: [URL] = []
        if let description = playlist.playlistDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            let destination = folder.appendingPathComponent("description.txt")
            try writeAtomically(Data(description.utf8), to: destination)
            created.append(destination)
        }
        if let source = playlist.artworkURL {
            let destination = folder.appendingPathComponent("cover.jpg")
            if !fileManager.fileExists(atPath: destination.path) {
                let response = try await fetcher.fetch(source)
                try writeAtomically(response.data, to: destination)
            }
            created.append(destination)
        }
        return created
    }

    public func recordLibraryCollections(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        downloadRoot: URL
    ) throws -> URL {
        guard !outputs.isEmpty else {
            throw NativeQobuzError.emptyCollection(plan.title)
        }
        let records = try collectionRecords(plan: plan, outputs: outputs, root: downloadRoot)
        var manifest = try QobuzLibraryManifestIO.load(at: downloadRoot, fileManager: fileManager)
        let updatedIDs = Set(records.map(\.id))
        manifest.collections.removeAll { updatedIDs.contains($0.id) }
        manifest.collections.append(contentsOf: records)
        manifest.collections.sort { $0.id < $1.id }
        try QobuzLibraryManifestIO.save(manifest, at: downloadRoot, fileManager: fileManager)
        return downloadRoot.appendingPathComponent(QobuzLibraryManifestIO.filename)
    }

    public func reusableAudioIndex(root: URL) throws -> [String: URL] {
        qobuzLog.debug("asset.reuse", "Reusable audio index scan started", metadata: ["downloadRoot": root.path])
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [:] }
        var result: [String: URL] = [:]
        while let manifestURL = enumerator.nextObject() as? URL {
            guard manifestURL.lastPathComponent == ".orpheus-provenance.json" else { continue }
            let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                qobuzLog.warning(
                    "asset.reuse",
                    "Ignored unsafe provenance manifest",
                    metadata: ["manifestPath": manifestURL.path]
                )
                continue
            }
            let manifest: ProvenanceManifest
            do {
                manifest = try JSONDecoder().decode(ProvenanceManifest.self, from: Data(contentsOf: manifestURL))
                guard manifest.version == 1 else {
                    qobuzLog.warning(
                        "asset.reuse",
                        "Ignored unsupported provenance manifest version",
                        metadata: ["manifestPath": manifestURL.path, "version": String(manifest.version)]
                    )
                    continue
                }
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
            for (filename, provenance) in manifest.files where isSafeLeafName(filename) {
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

    public func writeChecksumManifests(
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
            let destination = folder.appendingPathComponent("checksums.sha256")
            var entries: [String: String]
            do {
                entries = try checksumEntries(in: destination)
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
            let contents = entries.keys.sorted().map { "\(entries[$0]!)  \($0)" }.joined(separator: "\n") + "\n"
            try writeAtomically(Data(contents.utf8), to: destination)
            manifests.append(destination)
        }
        return manifests
    }

    public func expectedChecksum(for audioURL: URL) throws -> String? {
        let manifest = audioURL.deletingLastPathComponent().appendingPathComponent("checksums.sha256")
        return try checksumEntries(in: manifest)[audioURL.lastPathComponent]
    }

    public func provenance(for audioURL: URL) throws -> QobuzFileProvenance? {
        try provenanceManifest(in: audioURL.deletingLastPathComponent()).files[audioURL.lastPathComponent]
    }

    public func recordProvenance(_ provenance: QobuzFileProvenance, for audioURL: URL) throws {
        let folder = audioURL.deletingLastPathComponent()
        var manifest: ProvenanceManifest
        do {
            manifest = try provenanceManifest(in: folder)
        } catch {
            manifest = ProvenanceManifest()
            qobuzLog.warning(
                "asset.provenance",
                "Existing provenance could not be read and will be rebuilt",
                metadata: ["manifestPath": provenanceURL(in: folder).path],
                error: error
            )
        }
        manifest.files[audioURL.lastPathComponent] = provenance
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(try encoder.encode(manifest), to: provenanceURL(in: folder))
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

    public func markLibraryManaged(_ audioURLs: [URL]) throws {
        var visited = Set<URL>()
        for audioURL in audioURLs where visited.insert(audioURL.standardizedFileURL).inserted {
            guard let provenance = try provenance(for: audioURL), !provenance.isLibraryManaged else { continue }
            try recordProvenance(provenance.markingLibraryManaged(), for: audioURL)
        }
    }

    private func collectionRecords(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        root: URL
    ) throws -> [QobuzLibraryCollectionRecord] {
        switch plan.request {
        case .album:
            return [try albumRecord(outputs: outputs, root: root)]
        case .artist, .label:
            var order: [QobuzID] = []
            var grouped: [QobuzID: [(item: QobuzResolvedTrack, audioURL: URL)]] = [:]
            for output in outputs {
                if grouped[output.item.album.id] == nil { order.append(output.item.album.id) }
                grouped[output.item.album.id, default: []].append(output)
            }
            return try order.compactMap { id in
                guard let values = grouped[id] else { return nil }
                return try albumRecord(outputs: values, root: root)
            }
        case .track(let id):
            let output = outputs[0]
            let relative = try QobuzLibraryManifestIO.relativePath(of: output.audioURL, root: root)
            return [QobuzLibraryCollectionRecord(
                id: "track|\(id.rawValue)",
                kind: .track,
                qobuzID: id.rawValue,
                title: output.item.track.displayTitle,
                subtitle: output.item.track.performer?.name ?? output.item.album.artist.name,
                relativePath: relative,
                trackPaths: [relative],
                duration: output.item.track.duration
            )]
        case .playlist(let id):
            let folder = playlistFolder(title: plan.title, id: id, root: root)
            let relativeFolder = try QobuzLibraryManifestIO.relativePath(of: folder, root: root)
            let playlist: QobuzPlaylist? = if case .playlist(let value)? = plan.source { value } else { nil }
            let owner = playlist?.owner?.name
            let count = outputs.count
            return [QobuzLibraryCollectionRecord(
                id: "playlist|\(id.rawValue)",
                kind: .playlist,
                qobuzID: id.rawValue,
                title: plan.title,
                subtitle: [owner, "\(count) track\(count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · "),
                relativePath: relativeFolder,
                trackPaths: try outputs.map { try QobuzLibraryManifestIO.relativePath(of: $0.audioURL, root: root) },
                artworkRelativePath: existingRelativePath(folder.appendingPathComponent("cover.jpg"), root: root),
                collectionDescription: playlist?.playlistDescription,
                owner: owner,
                createdAt: playlist?.createdAt,
                updatedAt: playlist?.updatedAt,
                duration: playlist?.duration,
                sourceTrackCount: playlist?.tracksCount ?? playlist?.tracksTotal
            )]
        }
    }

    private func albumRecord(
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)],
        root: URL
    ) throws -> QobuzLibraryCollectionRecord {
        guard let first = outputs.first else { throw NativeQobuzError.emptyCollection("Album") }
        let album = first.item.album
        let folder = first.audioURL.deletingLastPathComponent()
        let relativeFolder = try QobuzLibraryManifestIO.relativePath(of: folder, root: root)
        return QobuzLibraryCollectionRecord(
            id: "album|\(album.id.rawValue)",
            kind: .album,
            qobuzID: album.id.rawValue,
            title: album.displayTitle,
            subtitle: "\(album.mainArtists.map(\.name).joined(separator: ", ")) · \(outputs.count) track\(outputs.count == 1 ? "" : "s")",
            relativePath: relativeFolder,
            trackPaths: try outputs.map { try QobuzLibraryManifestIO.relativePath(of: $0.audioURL, root: root) },
            artworkRelativePath: existingRelativePath(folder.appendingPathComponent("cover.jpg"), root: root),
            collectionDescription: album.albumDescription,
            duration: album.duration
        )
    }

    private func playlistFolder(title: String, id: QobuzID, root: URL) -> URL {
        let planner = StandardQobuzOutputPlanner()
        return root
            .appendingPathComponent("Playlists", isDirectory: true)
            .appendingPathComponent("\(planner.sanitize(title)) [\(planner.sanitize(id.rawValue))]", isDirectory: true)
    }

    private func portableRelativePath(from folder: URL, to target: URL, root: URL) throws -> String {
        let folderPath = try QobuzLibraryManifestIO.relativePath(of: folder, root: root)
        let targetPath = try QobuzLibraryManifestIO.relativePath(of: target, root: root)
        let folderParts = folderPath.split(separator: "/")
        let targetParts = targetPath.split(separator: "/")
        var shared = 0
        while shared < folderParts.count,
              shared < targetParts.count,
              folderParts[shared] == targetParts[shared] { shared += 1 }
        let parents = Array(repeating: "..", count: folderParts.count - shared)
        return (parents + targetParts.dropFirst(shared).map(String.init)).joined(separator: "/")
    }

    private func existingRelativePath(_ url: URL, root: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? QobuzLibraryManifestIO.relativePath(of: url, root: root)
    }

    private func isSafeLeafName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private func checksumEntries(in manifest: URL) throws -> [String: String] {
        guard fileManager.fileExists(atPath: manifest.path) else { return [:] }
        let contents = try String(contentsOf: manifest, encoding: .utf8)
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard line.count > 64 else { continue }
            let hashEnd = line.index(line.startIndex, offsetBy: 64)
            let hash = line[..<hashEnd]
            guard hash.allSatisfy(\.isHexDigit) else { continue }
            let filename = line[hashEnd...].drop(while: { $0 == " " || $0 == "*" })
            guard !filename.isEmpty else { continue }
            result[String(filename)] = String(hash)
        }
        return result
    }

    private func provenanceManifest(in folder: URL) throws -> ProvenanceManifest {
        let url = provenanceURL(in: folder)
        guard fileManager.fileExists(atPath: url.path) else { return ProvenanceManifest() }
        do {
            let manifest = try JSONDecoder().decode(ProvenanceManifest.self, from: Data(contentsOf: url))
            guard manifest.version == 1 else {
                throw NativeQobuzError.invalidResponse("Unsupported provenance manifest version")
            }
            return manifest
        } catch let error as NativeQobuzError {
            throw error
        } catch {
            throw NativeQobuzError.invalidResponse("Could not read download provenance: \(error.localizedDescription)")
        }
    }

    private func provenanceURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".orpheus-provenance.json")
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        var temporary: URL?
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
            temporary = staging
            try data.write(to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            if let temporary {
                do { try fileManager.removeItem(at: temporary) }
                catch {
                    qobuzLog.warning(
                        "asset.filesystem",
                        "Could not remove failed asset staging file",
                        metadata: ["stagingPath": temporary.path],
                        error: error
                    )
                }
            }
            qobuzLog.error(
                "asset.filesystem",
                "Atomic asset write failed",
                metadata: ["destinationPath": destination.path],
                error: error
            )
            throw NativeQobuzError.fileSystem(error.localizedDescription)
        }
    }
}

public extension QobuzAlbum {
    var originalArtworkURL: URL? {
        guard let source = image?.bestURL else { return nil }
        let value = source.absoluteString
        guard let separator = value.lastIndex(of: "_") else { return source }
        return URL(string: String(value[..<separator]) + "_org.jpg") ?? source
    }
}

private extension QobuzCollection {
    var archiveKind: QobuzArchiveKind {
        switch self {
        case .album, .artist, .label: .album
        case .track: .track
        case .playlist: .playlist
        }
    }

    var usesAlbumFolders: Bool {
        switch self {
        case .album, .artist, .label, .track, .playlist: true
        }
    }

    var writesAlbumCollectionAssets: Bool {
        switch self {
        case .album, .artist, .label: true
        case .track, .playlist: false
        }
    }
}
