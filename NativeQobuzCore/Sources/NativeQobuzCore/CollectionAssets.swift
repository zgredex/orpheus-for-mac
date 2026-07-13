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

public struct QobuzFileProvenance: Codable, Equatable, Sendable {
    public let qobuzTrackID: String
    public let qobuzAlbumID: String
    public let formatID: Int
    public let bitDepth: Int?
    public let samplingRate: Double?
    public let sha256: String

    public init(item: QobuzResolvedTrack, fileInfo: QobuzFileInfo, sha256: String) {
        qobuzTrackID = item.track.id.rawValue
        qobuzAlbumID = item.album.id.rawValue
        formatID = fileInfo.formatID
        bitDepth = fileInfo.bitDepth
        samplingRate = fileInfo.samplingRate
        self.sha256 = sha256
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

    private func ratesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) < 0.001
        default: false
        }
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
        do {
            let (data, response) = try await session.data(from: url)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw NativeQobuzError.http(response.statusCode, "Asset request failed")
            }
            guard !data.isEmpty else {
                throw NativeQobuzError.invalidResponse("Qobuz returned an empty asset")
            }
            return QobuzAssetResponse(data: data, mimeType: response.mimeType)
        } catch let error as NativeQobuzError {
            throw error
        } catch is CancellationError {
            throw NativeQobuzError.cancelled
        } catch {
            throw NativeQobuzError.network(error.localizedDescription)
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

    public func writePlaylist(
        plan: QobuzDownloadPlan,
        outputs: [(item: QobuzResolvedTrack, audioURL: URL)]
    ) throws -> URL? {
        guard case .playlist = plan.request, let first = outputs.first else { return nil }
        let folder = first.audioURL.deletingLastPathComponent()
        let name = StandardQobuzOutputPlanner().sanitize(plan.title)
        let destination = folder.appendingPathComponent("\(name).m3u")
        var lines = ["#EXTM3U"]
        for output in outputs {
            let duration = output.item.track.duration ?? -1
            let artist = output.item.track.performer?.name ?? output.item.album.artist.name
            lines.append("#EXTINF:\(duration), \(artist) - \(output.item.track.displayTitle)")
            lines.append(output.audioURL.lastPathComponent)
            lines.append("")
        }
        try writeAtomically(Data(lines.joined(separator: "\n").utf8), to: destination)
        return destination
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
            var entries = (try? checksumEntries(in: destination)) ?? [:]
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
        var manifest = (try? provenanceManifest(in: folder)) ?? ProvenanceManifest()
        manifest.files[audioURL.lastPathComponent] = provenance
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(try encoder.encode(manifest), to: provenanceURL(in: folder))
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
            if let temporary { try? fileManager.removeItem(at: temporary) }
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
    var usesAlbumFolders: Bool {
        switch self {
        case .album, .artist: true
        case .track, .playlist: false
        }
    }
}
