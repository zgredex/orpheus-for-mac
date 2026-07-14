import Foundation

/// The one persisted lifecycle shared by a queue item and its activity row.
/// Queue-only preparation uses `ready`/`loading`; transfer phases are mirrored
/// through `NativeViewModel.transitionDownload` so the two projections cannot drift.
enum NativeDownloadStatus: Codable, Equatable {
    case ready
    case loading
    case queued
    case resolving
    case downloading
    case tagging
    case validating
    case waitingForNetwork
    case paused
    case completed
    case failed(String)
    case cancelled

    var canStart: Bool {
        switch self {
        case .ready, .paused, .failed, .cancelled: true
        case .loading, .queued, .resolving, .downloading, .tagging, .validating,
             .waitingForNetwork, .completed: false
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .resolving, .downloading, .tagging, .validating, .waitingForNetwork: true
        default: false
        }
    }

    var isClearable: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    var canResume: Bool {
        switch self {
        case .paused, .cancelled: true
        default: false
        }
    }

    var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var diagnosticDescription: String {
        if case .failed(let message) = self { return "failed: \(message)" }
        return kind.rawValue
    }

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable {
        case ready, loading, queued, resolving, downloading, tagging, validating
        case waitingForNetwork, paused, completed, failed, cancelled
    }

    private var kind: Kind {
        switch self {
        case .ready: .ready
        case .loading: .loading
        case .queued: .queued
        case .resolving: .resolving
        case .downloading: .downloading
        case .tagging: .tagging
        case .validating: .validating
        case .waitingForNetwork: .waitingForNetwork
        case .paused: .paused
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ready: self = .ready
        case .loading: self = .loading
        case .queued: self = .queued
        case .resolving: self = .resolving
        case .downloading: self = .downloading
        case .tagging: self = .tagging
        case .validating: self = .validating
        case .waitingForNetwork: self = .waitingForNetwork
        case .paused: self = .paused
        case .completed: self = .completed
        case .failed: self = .failed(try container.decode(String.self, forKey: .message))
        case .cancelled: self = .cancelled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if case .failed(let message) = self {
            try container.encode(message, forKey: .message)
        }
    }
}
