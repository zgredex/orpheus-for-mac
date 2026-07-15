import Foundation
import NativeQobuzCore

enum NativeLibraryStatus: Equatable {
    case verified
    case complete(Int)
    case partial(verified: Int, total: Int, problems: Int)
    case indexed(verified: Int, problems: Int)

    init?(_ coverage: QobuzArchiveCoverage) {
        guard coverage.matchedCount > 0 else { return nil }
        if coverage.isComplete {
            self = coverage.expectedCount == 1
                ? .verified
                : .complete(coverage.expectedCount ?? coverage.verifiedCount)
        } else if let expectedCount = coverage.expectedCount {
            self = .partial(
                verified: coverage.verifiedCount,
                total: expectedCount,
                problems: coverage.problemCount
            )
        } else {
            self = .indexed(
                verified: coverage.verifiedCount,
                problems: coverage.problemCount
            )
        }
    }

    var label: String {
        switch self {
        case .verified:
            "Verified"
        case .complete(let count):
            "\(count)/\(count) verified"
        case .partial(let verified, let total, let problems):
            verified == 0 && problems > 0 ? "Needs attention" : "\(verified)/\(total) verified"
        case .indexed(let verified, let problems):
            if verified == 0, problems > 0 { "Needs attention" }
            else if problems > 0 { "\(verified) verified · \(problems) issue\(problems == 1 ? "" : "s")" }
            else { "\(verified) verified" }
        }
    }

    var compactLabel: String {
        switch self {
        case .verified: "Verified"
        case .complete: "All verified"
        case .partial(let verified, let total, _): "\(verified)/\(total)"
        case .indexed(let verified, let problems):
            problems > 0 ? "\(problems) issue\(problems == 1 ? "" : "s")" : "\(verified) verified"
        }
    }

    var hasProblems: Bool {
        switch self {
        case .verified, .complete: false
        case .partial(let verified, let total, let problems): problems > 0 || verified < total
        case .indexed(_, let problems): problems > 0
        }
    }
}

struct NativeLibraryFileProblem: Identifiable, Equatable {
    let track: QobuzArchiveTrack
    let diagnostic: String?

    var id: QobuzArchiveTrack.ID { track.id }

    var reasonTitle: String {
        switch track.integrity {
        case .verified: "Verified"
        case .missing: "Missing"
        case .checksumMismatch: "Changed"
        case .metadataConflict: "Conflict"
        case .unreadable: "Unreadable"
        }
    }

    var reasonDetail: String {
        switch track.integrity {
        case .verified:
            "The file matches its recorded checksum."
        case .missing:
            "The archived audio file is no longer present at this path."
        case .checksumMismatch:
            "The file no longer matches its recorded SHA-256 checksum."
        case .metadataConflict:
            "The provenance record and checksums.sha256 disagree."
        case .unreadable:
            diagnostic ?? "The file could not be read or hashed."
        }
    }

    var systemImage: String {
        switch track.integrity {
        case .verified: "checkmark.seal.fill"
        case .missing: "questionmark.folder"
        case .checksumMismatch: "exclamationmark.triangle.fill"
        case .metadataConflict: "arrow.trianglehead.2.clockwise.rotate.90"
        case .unreadable: "xmark.octagon.fill"
        }
    }

    var isAutomaticallyRepairable: Bool {
        track.integrity != .verified && track.audioFormat != nil
    }

    var repairabilityDetail: String {
        if isAutomaticallyRepairable {
            return "Orpheus can restore this exact Qobuz track at its archived quality and path."
        }
        return "Archived format \(track.formatID) is not supported for automatic repair."
    }
}

struct NativeLibraryIndexProblem: Identifiable, Equatable {
    let id: String
    let relativePath: String
    let message: String
}

extension QobuzArchiveSnapshot {
    var nativeFileProblems: [NativeLibraryFileProblem] {
        let diagnostics = Dictionary(grouping: issues, by: \.relativePath)
        return tracks.compactMap { track in
            guard track.integrity != .verified else { return nil }
            return NativeLibraryFileProblem(
                track: track,
                diagnostic: diagnostics[track.relativePath]?.first?.message
            )
        }
    }

    var nativeIndexProblems: [NativeLibraryIndexProblem] {
        let trackProblemPaths = Set(nativeFileProblems.map { $0.track.relativePath })
        return issues.enumerated().compactMap { offset, issue in
            guard !trackProblemPaths.contains(issue.relativePath) else { return nil }
            return NativeLibraryIndexProblem(
                id: "\(offset):\(issue.relativePath):\(issue.message)",
                relativePath: issue.relativePath,
                message: issue.message
            )
        }
    }
}
