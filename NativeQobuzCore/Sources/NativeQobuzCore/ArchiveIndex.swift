import Foundation

public enum QobuzArchiveKind: String, Codable, CaseIterable, Equatable, Sendable {
    case album
    case track
    case playlist
    case unclassified
}

public enum QobuzArchiveIntegrity: String, Codable, Equatable, Sendable {
    case verified
    case missing
    case checksumMismatch
    case metadataConflict
    case unreadable
}

public struct QobuzArchiveTrack: Codable, Equatable, Identifiable, Sendable {
    public let relativePath: String
    public let qobuzTrackID: String
    public let qobuzAlbumID: String
    public let formatID: Int
    public let bitDepth: Int?
    public let samplingRate: Double?
    public let expectedSHA256: String
    public let actualSHA256: String?
    public let byteCount: Int64?
    public let integrity: QobuzArchiveIntegrity
    public let archiveKind: QobuzArchiveKind
    public let isLibraryManaged: Bool

    public var id: String { relativePath }
    /// Typed view of the exact archived format. The manifest keeps the raw ID
    /// so future formats remain readable even before the app supports repair.
    public var audioFormat: QobuzAudioFormat? { QobuzAudioFormat(formatID: formatID) }

    public init(
        relativePath: String,
        qobuzTrackID: String,
        qobuzAlbumID: String,
        formatID: Int,
        bitDepth: Int? = nil,
        samplingRate: Double? = nil,
        expectedSHA256: String,
        actualSHA256: String? = nil,
        byteCount: Int64? = nil,
        integrity: QobuzArchiveIntegrity,
        archiveKind: QobuzArchiveKind = .unclassified,
        isLibraryManaged: Bool = false
    ) {
        self.relativePath = relativePath
        self.qobuzTrackID = qobuzTrackID
        self.qobuzAlbumID = qobuzAlbumID
        self.formatID = formatID
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.byteCount = byteCount
        self.integrity = integrity
        self.archiveKind = archiveKind
        self.isLibraryManaged = isLibraryManaged
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case qobuzTrackID
        case qobuzAlbumID
        case formatID
        case bitDepth
        case samplingRate
        case expectedSHA256
        case actualSHA256
        case byteCount
        case integrity
        case archiveKind
        case isLibraryManaged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        qobuzTrackID = try container.decode(String.self, forKey: .qobuzTrackID)
        qobuzAlbumID = try container.decode(String.self, forKey: .qobuzAlbumID)
        formatID = try container.decode(Int.self, forKey: .formatID)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        samplingRate = try container.decodeIfPresent(Double.self, forKey: .samplingRate)
        expectedSHA256 = try container.decode(String.self, forKey: .expectedSHA256)
        actualSHA256 = try container.decodeIfPresent(String.self, forKey: .actualSHA256)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
        integrity = try container.decode(QobuzArchiveIntegrity.self, forKey: .integrity)
        archiveKind = try container.decodeIfPresent(QobuzArchiveKind.self, forKey: .archiveKind)
            ?? .unclassified
        isLibraryManaged = try container.decodeIfPresent(Bool.self, forKey: .isLibraryManaged) ?? false
    }
}

public struct QobuzArchiveIssue: Codable, Equatable, Sendable {
    public let relativePath: String
    public let message: String

    public init(relativePath: String, message: String) {
        self.relativePath = relativePath
        self.message = message
    }
}

public struct QobuzArchiveCoverage: Equatable, Sendable {
    public let matchedCount: Int
    public let verifiedCount: Int
    public let problemCount: Int
    public let expectedCount: Int?

    public init(
        matchedCount: Int,
        verifiedCount: Int,
        problemCount: Int,
        expectedCount: Int?
    ) {
        self.matchedCount = matchedCount
        self.verifiedCount = verifiedCount
        self.problemCount = problemCount
        self.expectedCount = expectedCount
    }

    public var isComplete: Bool {
        guard let expectedCount else { return false }
        return expectedCount > 0
            && verifiedCount == expectedCount
            && problemCount == 0
    }
}

public struct QobuzArchiveEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: QobuzArchiveKind
    public let title: String
    public let subtitle: String
    public let relativePath: String
    public let tracks: [QobuzArchiveTrack]

    public var verifiedCount: Int { tracks.count { $0.integrity == .verified } }
    public var problemCount: Int { tracks.count - verifiedCount }
    public var byteCount: Int64? {
        let unique = Dictionary(grouping: tracks, by: \.relativePath).compactMap { $0.value.first }
        let sizes = unique.compactMap(\.byteCount)
        return sizes.count == unique.count ? sizes.reduce(0, +) : nil
    }

    public init(
        id: String,
        kind: QobuzArchiveKind,
        title: String,
        subtitle: String,
        relativePath: String,
        tracks: [QobuzArchiveTrack]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.relativePath = relativePath
        self.tracks = tracks
    }
}

/// The sole projection from physical archive records into user-facing downloads.
/// Collection records allow one verified file to belong to several playlists or
/// a standalone-track entry without duplicating the audio on disk.
public struct QobuzArchiveLibrary: Equatable, Sendable {
    public let entries: [QobuzArchiveEntry]

    public init(
        tracks: [QobuzArchiveTrack],
        collections: [QobuzLibraryCollectionRecord] = []
    ) {
        let tracksByPath = Dictionary(uniqueKeysWithValues: tracks.map { ($0.relativePath, $0) })
        let logicalEntries = collections.compactMap { record -> QobuzArchiveEntry? in
            let values = record.trackPaths.compactMap { tracksByPath[$0] }
            guard !values.isEmpty else { return nil }
            return QobuzArchiveEntry(
                id: record.id,
                kind: record.kind,
                title: record.title,
                subtitle: record.subtitle,
                relativePath: record.relativePath,
                tracks: values
            )
        }
        let referencedPaths = Set(collections.flatMap(\.trackPaths))
        let fallbackTracks = tracks.filter {
            !referencedPaths.contains($0.relativePath) && !$0.isLibraryManaged
        }
        let grouped = Dictionary(grouping: fallbackTracks, by: Self.groupKey)
        let fallbackEntries = grouped.keys.compactMap { key -> QobuzArchiveEntry? in
            guard let values = grouped[key], let first = values.first else { return nil }
            let sortedTracks = values.sorted { $0.relativePath < $1.relativePath }
            let directory = Self.directoryPath(for: first.relativePath)
            let title: String
            let subtitle: String
            let relativePath: String

            switch first.archiveKind {
            case .album:
                title = Self.lastComponent(directory, fallback: "Album \(first.qobuzAlbumID)")
                let artist = Self.lastComponent(
                    Self.directoryPath(for: directory),
                    fallback: "Album"
                )
                subtitle = "\(artist) · \(sortedTracks.count) file\(sortedTracks.count == 1 ? "" : "s")"
                relativePath = directory
            case .track:
                title = Self.filenameStem(first.relativePath)
                subtitle = Self.lastComponent(directory, fallback: "Standalone track")
                relativePath = first.relativePath
            case .playlist:
                title = Self.lastComponent(directory, fallback: "Playlist")
                subtitle = "Playlist · \(sortedTracks.count) file\(sortedTracks.count == 1 ? "" : "s")"
                relativePath = directory
            case .unclassified:
                title = Self.lastComponent(directory, fallback: Self.filenameStem(first.relativePath))
                subtitle = "Older download · \(sortedTracks.count) file\(sortedTracks.count == 1 ? "" : "s")"
                relativePath = directory.isEmpty ? first.relativePath : directory
            }

            return QobuzArchiveEntry(
                id: key,
                kind: first.archiveKind,
                title: title,
                subtitle: subtitle,
                relativePath: relativePath,
                tracks: sortedTracks
            )
        }
        entries = (logicalEntries + fallbackEntries).sorted {
            if $0.kind != $1.kind {
                return Self.kindOrder($0.kind) < Self.kindOrder($1.kind)
            }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    public func entries(of kind: QobuzArchiveKind) -> [QobuzArchiveEntry] {
        entries.filter { $0.kind == kind }
    }

    public func count(of kind: QobuzArchiveKind) -> Int {
        entries.count { $0.kind == kind }
    }

    private static func groupKey(_ track: QobuzArchiveTrack) -> String {
        switch track.archiveKind {
        case .album:
            "album|\(track.qobuzAlbumID)"
        case .track:
            "track|\(track.relativePath)"
        case .playlist:
            "playlist|\(directoryPath(for: track.relativePath))"
        case .unclassified:
            "unclassified|\(directoryPath(for: track.relativePath))"
        }
    }

    private static func kindOrder(_ kind: QobuzArchiveKind) -> Int {
        switch kind {
        case .album: 0
        case .track: 1
        case .playlist: 2
        case .unclassified: 3
        }
    }

    private static func directoryPath(for relativePath: String) -> String {
        let value = (relativePath as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    private static func lastComponent(_ path: String, fallback: String) -> String {
        guard !path.isEmpty else { return fallback }
        let value = (path as NSString).lastPathComponent
        return value.isEmpty || value == "." ? fallback : value
    }

    private static func filenameStem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

public struct QobuzArchiveSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let rootPath: String
    public let scannedAt: Date
    public let tracks: [QobuzArchiveTrack]
    public let issues: [QobuzArchiveIssue]
    public let collections: [QobuzLibraryCollectionRecord]

    public init(
        version: Int = 1,
        rootPath: String,
        scannedAt: Date = Date(),
        tracks: [QobuzArchiveTrack],
        issues: [QobuzArchiveIssue] = [],
        collections: [QobuzLibraryCollectionRecord] = []
    ) {
        self.version = version
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.tracks = tracks
        self.issues = issues
        self.collections = collections
    }

    private enum CodingKeys: String, CodingKey {
        case version, rootPath, scannedAt, tracks, issues, collections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        tracks = try container.decode([QobuzArchiveTrack].self, forKey: .tracks)
        issues = try container.decodeIfPresent([QobuzArchiveIssue].self, forKey: .issues) ?? []
        collections = try container.decodeIfPresent([QobuzLibraryCollectionRecord].self, forKey: .collections) ?? []
    }

    public var library: QobuzArchiveLibrary { QobuzArchiveLibrary(tracks: tracks, collections: collections) }
    public var albumCount: Int { library.count(of: .album) }
    public var standaloneTrackCount: Int { library.count(of: .track) }
    public var playlistCount: Int { library.count(of: .playlist) }
    public var unclassifiedCount: Int { library.count(of: .unclassified) }
    public var verifiedCount: Int { tracks.count { $0.integrity == .verified } }
    public var problemCount: Int {
        let trackProblemPaths = Set(
            tracks.filter { $0.integrity != .verified }.map(\.relativePath)
        )
        let standaloneIssues = issues.count { !trackProblemPaths.contains($0.relativePath) }
        return trackProblemPaths.count + standaloneIssues
    }

    public func coverage(
        trackIDs: [QobuzID],
        albumID: QobuzID? = nil
    ) -> QobuzArchiveCoverage {
        let expectedIDs = Set(trackIDs.map(\.rawValue))
        let candidates = tracks.filter { track in
            expectedIDs.contains(track.qobuzTrackID)
                && albumID.map { track.qobuzAlbumID == $0.rawValue } != false
        }
        return Self.coverage(for: candidates, expectedCount: expectedIDs.count)
    }

    public func coverage(
        trackID: QobuzID,
        albumID: QobuzID? = nil
    ) -> QobuzArchiveCoverage {
        coverage(trackIDs: [trackID], albumID: albumID)
    }

    public func coverage(albumID: QobuzID) -> QobuzArchiveCoverage {
        Self.coverage(
            for: tracks.filter { $0.qobuzAlbumID == albumID.rawValue },
            expectedCount: nil
        )
    }

    private static func coverage(
        for candidates: [QobuzArchiveTrack],
        expectedCount: Int?
    ) -> QobuzArchiveCoverage {
        let groups = Dictionary(grouping: candidates, by: \.qobuzTrackID)
        let verified = groups.values.count { records in
            records.contains { $0.integrity == .verified }
        }
        let problems = groups.values.count { records in
            records.contains { $0.integrity != .verified }
        }
        return QobuzArchiveCoverage(
            matchedCount: groups.count,
            verifiedCount: verified,
            problemCount: problems,
            expectedCount: expectedCount
        )
    }
}

public protocol QobuzArchiveScanning: Sendable {
    func scan(root: URL) async throws -> QobuzArchiveSnapshot
}

public struct QobuzArchiveScanner: QobuzArchiveScanning, @unchecked Sendable {
    private struct ProvenanceManifest: Decodable {
        let version: Int
        let files: [String: QobuzFileProvenance]
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(root: URL) async throws -> QobuzArchiveSnapshot {
        let root = root.standardizedFileURL
        let scanID = UUID().uuidString
        let started = Date()
        let scanMetadata = ["libraryScanID": scanID, "downloadRoot": root.path]
        qobuzLog.notice("library.scan", "Library integrity scan started", metadata: scanMetadata)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            qobuzLog.warning(
                "library.scan",
                "Library scan found no download folder",
                metadata: scanMetadata
            )
            return QobuzArchiveSnapshot(
                rootPath: root.path,
                tracks: [],
                issues: [QobuzArchiveIssue(relativePath: ".", message: "Download folder does not exist yet.")]
            )
        }

        let enumeration = try manifestURLs(in: root)
        var issues = enumeration.issues
        qobuzLog.info(
            "library.scan",
            "Provenance manifests enumerated",
            metadata: scanMetadata.merging([
                "manifestCount": String(enumeration.urls.count),
                "enumerationIssues": String(enumeration.issues.count)
            ]) { _, new in new }
        )

        var tracks: [QobuzArchiveTrack] = []
        for manifestURL in enumeration.urls {
            try Task.checkCancellation()
            let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            do {
                qobuzLog.trace(
                    "library.scan.manifest",
                    "Reading provenance manifest",
                    metadata: scanMetadata.merging(["manifestPath": manifestURL.path]) { _, new in new }
                )
                let manifest = try JSONDecoder().decode(
                    ProvenanceManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                guard manifest.version == 1 else {
                    throw NativeQobuzError.invalidResponse("Unsupported provenance manifest version \(manifest.version).")
                }
                let folder = manifestURL.deletingLastPathComponent()
                let checksumURL = folder.appendingPathComponent("checksums.sha256")
                let checksumEntries: [String: String]
                do {
                    checksumEntries = try self.checksumEntries(at: checksumURL)
                } catch {
                    checksumEntries = [:]
                    qobuzLog.warning(
                        "library.scan.checksum",
                        "Checksum manifest could not be read",
                        metadata: scanMetadata.merging(["checksumPath": checksumURL.path]) { _, new in new },
                        error: error
                    )
                }
                let hasPlaylistManifest = playlistManifestReferencesFiles(
                    in: folder,
                    filenames: Set(manifest.files.keys)
                )

                for filename in manifest.files.keys.sorted() {
                    try Task.checkCancellation()
                    guard Self.isSafeLeafName(filename), let provenance = manifest.files[filename] else {
                        issues.append(QobuzArchiveIssue(
                            relativePath: Self.relativePath(of: manifestURL, root: root),
                            message: "Ignored an unsafe provenance filename."
                        ))
                        continue
                    }
                    let audioURL = folder.appendingPathComponent(filename).standardizedFileURL
                    let relativePath = Self.relativePath(of: audioURL, root: root)
                    let archiveKind = Self.resolvedArchiveKind(
                        provenance.archiveKind,
                        relativePath: relativePath,
                        hasPlaylistManifest: hasPlaylistManifest
                    )
                    let manifestChecksum = checksumEntries[filename]
                    let metadataConflict = manifestChecksum.map {
                        $0.caseInsensitiveCompare(provenance.sha256) != .orderedSame
                    } ?? false
                    let exists = fileManager.fileExists(atPath: audioURL.path)
                    var actualChecksum: String?
                    var byteCount: Int64?
                    let integrity: QobuzArchiveIntegrity

                    if !exists {
                        integrity = .missing
                    } else {
                        do {
                            let attributes = try fileManager.attributesOfItem(atPath: audioURL.path)
                            byteCount = (attributes[.size] as? NSNumber)?.int64Value
                            actualChecksum = try MusicFileIntegrity.sha256(of: audioURL)
                            if metadataConflict {
                                integrity = .metadataConflict
                            } else if actualChecksum?.caseInsensitiveCompare(provenance.sha256) == .orderedSame {
                                integrity = .verified
                            } else {
                                integrity = .checksumMismatch
                            }
                        } catch {
                            integrity = .unreadable
                            qobuzLog.error(
                                "library.scan.track",
                                "Library audio file could not be inspected",
                                metadata: scanMetadata.merging(["relativePath": relativePath]) { _, new in new },
                                error: error
                            )
                            issues.append(QobuzArchiveIssue(
                                relativePath: relativePath,
                                message: error.localizedDescription
                            ))
                        }
                    }

                    tracks.append(QobuzArchiveTrack(
                        relativePath: relativePath,
                        qobuzTrackID: provenance.qobuzTrackID,
                        qobuzAlbumID: provenance.qobuzAlbumID,
                        formatID: provenance.formatID,
                        bitDepth: provenance.bitDepth,
                        samplingRate: provenance.samplingRate,
                        expectedSHA256: provenance.sha256,
                        actualSHA256: actualChecksum,
                        byteCount: byteCount,
                        integrity: integrity,
                        archiveKind: archiveKind,
                        isLibraryManaged: provenance.isLibraryManaged
                    ))
                    qobuzLog.trace(
                        "library.scan.track",
                        "Library audio integrity evaluated",
                        metadata: scanMetadata.merging([
                            "relativePath": relativePath,
                            "trackID": provenance.qobuzTrackID,
                            "integrity": integrity.rawValue,
                            "byteCount": byteCount.map(String.init) ?? "unknown"
                        ]) { _, new in new }
                    )
                }
            } catch is CancellationError {
                qobuzLog.notice("library.scan", "Library integrity scan cancelled", metadata: scanMetadata)
                throw NativeQobuzError.cancelled
            } catch {
                qobuzLog.error(
                    "library.scan.manifest",
                    "Provenance manifest could not be inspected",
                    metadata: scanMetadata.merging(["manifestPath": manifestURL.path]) { _, new in new },
                    error: error
                )
                issues.append(QobuzArchiveIssue(
                    relativePath: Self.relativePath(of: manifestURL, root: root),
                    message: error.localizedDescription
                ))
            }
        }

        tracks.sort {
            ($0.qobuzAlbumID, $0.relativePath) < ($1.qobuzAlbumID, $1.relativePath)
        }
        var collections: [QobuzLibraryCollectionRecord] = []
        do {
            let manifest = try QobuzLibraryManifestIO.load(at: root, fileManager: fileManager)
            collections = manifest.collections.filter { record in
                let paths = [record.relativePath] + record.trackPaths + [record.artworkRelativePath].compactMap { $0 }
                let safe = paths.allSatisfy(QobuzLibraryManifestIO.isSafeRelativePath)
                if !safe {
                    issues.append(QobuzArchiveIssue(
                        relativePath: QobuzLibraryManifestIO.filename,
                        message: "Ignored a collection containing an unsafe relative path."
                    ))
                }
                return safe
            }
        } catch {
            qobuzLog.error(
                "library.scan.manifest",
                "Library collection manifest could not be loaded",
                metadata: scanMetadata,
                error: error
            )
            issues.append(QobuzArchiveIssue(
                relativePath: QobuzLibraryManifestIO.filename,
                message: error.localizedDescription
            ))
        }
        let snapshot = QobuzArchiveSnapshot(
            rootPath: root.path,
            tracks: tracks,
            issues: issues,
            collections: collections
        )
        qobuzLog.notice(
            "library.scan",
            "Library integrity scan completed",
            metadata: scanMetadata.merging([
                "trackCount": String(snapshot.tracks.count),
                "verifiedCount": String(snapshot.verifiedCount),
                "problemCount": String(snapshot.problemCount),
                "issueCount": String(snapshot.issues.count),
                "collectionCount": String(snapshot.collections.count),
                "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
            ]) { _, new in new }
        )
        return snapshot
    }

    private func manifestURLs(in root: URL) throws -> (urls: [URL], issues: [QobuzArchiveIssue]) {
        var issues: [QobuzArchiveIssue] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                qobuzLog.warning(
                    "library.scan.enumeration",
                    "Download folder enumeration encountered an error",
                    metadata: ["path": url.path],
                    error: error
                )
                issues.append(QobuzArchiveIssue(
                    relativePath: Self.relativePath(of: url, root: root),
                    message: error.localizedDescription
                ))
                return true
            }
        ) else {
            throw NativeQobuzError.fileSystem("Could not enumerate the download folder.")
        }
        var urls: [URL] = []
        while let value = enumerator.nextObject() as? URL {
            if value.lastPathComponent == ".orpheus-provenance.json" { urls.append(value) }
        }
        return (urls, issues)
    }

    private func checksumEntries(at url: URL) throws -> [String: String] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard line.count > 64 else { continue }
            let hashEnd = line.index(line.startIndex, offsetBy: 64)
            let hash = line[..<hashEnd]
            guard hash.allSatisfy(\.isHexDigit) else { continue }
            let filename = line[hashEnd...].drop(while: { $0 == " " || $0 == "*" })
            if !filename.isEmpty { result[String(filename)] = String(hash) }
        }
        return result
    }

    private func playlistManifestReferencesFiles(in folder: URL, filenames: Set<String>) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for url in contents where ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let referencesKnownFile = text.split(whereSeparator: \.isNewline).contains { line in
                guard !line.hasPrefix("#") else { return false }
                return filenames.contains(URL(fileURLWithPath: String(line)).lastPathComponent)
            }
            if referencesKnownFile { return true }
        }
        return false
    }

    private static func resolvedArchiveKind(
        _ recordedKind: QobuzArchiveKind,
        relativePath: String,
        hasPlaylistManifest: Bool
    ) -> QobuzArchiveKind {
        guard recordedKind == .unclassified else { return recordedKind }

        // Version-one provenance predates archiveKind. These are the exact
        // layouts produced by StandardQobuzOutputPlanner, applied only as a
        // compatibility migration for those older manifests.
        let components = relativePath.split(separator: "/")
        if components.count >= 3 { return .album }
        if components.count == 2 { return hasPlaylistManifest ? .playlist : .track }
        return .unclassified
    }

    private static func isSafeLeafName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && URL(fileURLWithPath: value).lastPathComponent == value
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        if path == rootPath { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
