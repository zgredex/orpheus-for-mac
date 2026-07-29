import Foundation

/// Immutable lookup projection built exactly once for each archive snapshot.
/// The snapshot remains authoritative; this index only accelerates deterministic
/// reads of that value and is never mutated independently.
public struct QobuzArchiveLookupIndex: Equatable, Sendable {
    public let library: QobuzArchiveLibrary
    public let verifiedCount: Int
    public let problemCount: Int
    public let problemTracks: [QobuzArchiveTrack]
    public let problemTrackPaths: Set<String>
    public let issuesByPath: [String: [QobuzArchiveIssue]]
    public let standaloneIssues: [QobuzArchiveIssue]

    private let countsByKind: [QobuzArchiveKind: Int]
    private let coverageByTrackID: [String: CoverageState]
    private let coverageByAlbumTrack: [AlbumTrackKey: CoverageState]
    private let coverageByAlbumID: [String: QobuzArchiveCoverage]

    public init(
        tracks: [QobuzArchiveTrack],
        issues: [QobuzArchiveIssue],
        collections: [QobuzLibraryCollectionRecord]
    ) {
        let interval = QobuzPerformanceSignposts.begin(
            "ArchiveIndexBuild",
            metadata: "tracks=\(tracks.count) issues=\(issues.count) collections=\(collections.count)"
        )
        defer {
            QobuzPerformanceSignposts.end(
                interval,
                metadata: "tracks=\(tracks.count)"
            )
        }
        library = QobuzArchiveLibrary(tracks: tracks, collections: collections)
        countsByKind = Dictionary(
            grouping: library.entries,
            by: \.kind
        ).mapValues(\.count)

        var trackStates: [String: CoverageState] = [:]
        var albumTrackStates: [AlbumTrackKey: CoverageState] = [:]
        var albumStates: [String: [String: CoverageState]] = [:]
        var problems: [QobuzArchiveTrack] = []
        var verified = 0
        for track in tracks {
            let isVerified = track.integrity == .verified
            verified += isVerified ? 1 : 0
            if !isVerified { problems.append(track) }
            trackStates[track.qobuzTrackID, default: CoverageState()].record(isVerified: isVerified)
            let albumTrackKey = AlbumTrackKey(
                albumID: track.qobuzAlbumID,
                trackID: track.qobuzTrackID
            )
            albumTrackStates[albumTrackKey, default: CoverageState()].record(isVerified: isVerified)
            albumStates[track.qobuzAlbumID, default: [:]][
                track.qobuzTrackID,
                default: CoverageState()
            ].record(isVerified: isVerified)
        }
        verifiedCount = verified
        problemTracks = problems
        let indexedProblemPaths = Set(problems.map(\.relativePath))
        problemTrackPaths = indexedProblemPaths
        issuesByPath = Dictionary(grouping: issues, by: \.relativePath)
        let indexedStandaloneIssues = issues.filter {
            !indexedProblemPaths.contains($0.relativePath)
        }
        standaloneIssues = indexedStandaloneIssues
        problemCount = indexedProblemPaths.count + indexedStandaloneIssues.count
        coverageByTrackID = trackStates
        coverageByAlbumTrack = albumTrackStates
        coverageByAlbumID = albumStates.mapValues { states in
            Self.coverage(states.values, expectedCount: nil)
        }
    }

    public func count(of kind: QobuzArchiveKind) -> Int {
        countsByKind[kind, default: 0]
    }

    public func coverage(
        trackIDs: [QobuzID],
        albumID: QobuzID? = nil
    ) -> QobuzArchiveCoverage {
        let expectedIDs = Set(trackIDs.map(\.rawValue))
        let states = expectedIDs.compactMap { trackID -> CoverageState? in
            if let albumID {
                return coverageByAlbumTrack[
                    AlbumTrackKey(albumID: albumID.rawValue, trackID: trackID)
                ]
            }
            return coverageByTrackID[trackID]
        }
        return Self.coverage(states, expectedCount: expectedIDs.count)
    }

    public func coverage(albumID: QobuzID) -> QobuzArchiveCoverage {
        coverageByAlbumID[albumID.rawValue]
            ?? QobuzArchiveCoverage(
                matchedCount: 0,
                verifiedCount: 0,
                problemCount: 0,
                expectedCount: nil
            )
    }

    private static func coverage<S: Sequence>(
        _ states: S,
        expectedCount: Int?
    ) -> QobuzArchiveCoverage where S.Element == CoverageState {
        var matched = 0
        var verified = 0
        var problems = 0
        for state in states {
            matched += 1
            verified += state.hasVerified ? 1 : 0
            problems += state.hasProblem ? 1 : 0
        }
        return QobuzArchiveCoverage(
            matchedCount: matched,
            verifiedCount: verified,
            problemCount: problems,
            expectedCount: expectedCount
        )
    }
}

private struct AlbumTrackKey: Hashable, Sendable {
    let albumID: String
    let trackID: String
}

private struct CoverageState: Equatable, Sendable {
    private(set) var hasVerified = false
    private(set) var hasProblem = false

    mutating func record(isVerified: Bool) {
        if isVerified {
            hasVerified = true
        } else {
            hasProblem = true
        }
    }
}
