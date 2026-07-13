import Foundation

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

    public var id: String { relativePath }

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
        integrity: QobuzArchiveIntegrity
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

public struct QobuzArchiveSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let rootPath: String
    public let scannedAt: Date
    public let tracks: [QobuzArchiveTrack]
    public let issues: [QobuzArchiveIssue]

    public init(
        version: Int = 1,
        rootPath: String,
        scannedAt: Date = Date(),
        tracks: [QobuzArchiveTrack],
        issues: [QobuzArchiveIssue] = []
    ) {
        self.version = version
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.tracks = tracks
        self.issues = issues
    }

    public var albumCount: Int { Set(tracks.map(\.qobuzAlbumID)).count }
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
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return QobuzArchiveSnapshot(
                rootPath: root.path,
                tracks: [],
                issues: [QobuzArchiveIssue(relativePath: ".", message: "Download folder does not exist yet.")]
            )
        }

        let enumeration = try manifestURLs(in: root)
        var issues = enumeration.issues

        var tracks: [QobuzArchiveTrack] = []
        for manifestURL in enumeration.urls {
            try Task.checkCancellation()
            let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            do {
                let manifest = try JSONDecoder().decode(
                    ProvenanceManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                guard manifest.version == 1 else {
                    throw NativeQobuzError.invalidResponse("Unsupported provenance manifest version \(manifest.version).")
                }
                let folder = manifestURL.deletingLastPathComponent()
                let checksumEntries = (try? checksumEntries(
                    at: folder.appendingPathComponent("checksums.sha256")
                )) ?? [:]

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
                        integrity: integrity
                    ))
                }
            } catch {
                issues.append(QobuzArchiveIssue(
                    relativePath: Self.relativePath(of: manifestURL, root: root),
                    message: error.localizedDescription
                ))
            }
        }

        tracks.sort {
            ($0.qobuzAlbumID, $0.relativePath) < ($1.qobuzAlbumID, $1.relativePath)
        }
        return QobuzArchiveSnapshot(rootPath: root.path, tracks: tracks, issues: issues)
    }

    private func manifestURLs(in root: URL) throws -> (urls: [URL], issues: [QobuzArchiveIssue]) {
        var issues: [QobuzArchiveIssue] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
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
