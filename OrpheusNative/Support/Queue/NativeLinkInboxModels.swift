import Foundation
import NativeQobuzCore

enum NativeLinkReviewStatus: Codable, Equatable, Sendable {
    case pending
    case checking
    case available
    case partial(String)
    case unavailable(String)
    case failed(String)

    var message: String? {
        switch self {
        case .partial(let value), .unavailable(let value), .failed(let value): value
        case .pending, .checking, .available: nil
        }
    }

    var isReviewed: Bool {
        switch self {
        case .pending, .checking: false
        case .available, .partial, .unavailable, .failed: true
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case pending, checking, available, partial, unavailable, failed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .checking: self = .checking
        case .available: self = .available
        case .partial: self = .partial(try container.decode(String.self, forKey: .message))
        case .unavailable: self = .unavailable(try container.decode(String.self, forKey: .message))
        case .failed: self = .failed(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try container.encode(Kind.pending, forKey: .kind)
        case .checking: try container.encode(Kind.checking, forKey: .kind)
        case .available: try container.encode(Kind.available, forKey: .kind)
        case .partial(let message):
            try container.encode(Kind.partial, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .unavailable(let message):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

struct NativeLinkInboxItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let originalURL: String
    let request: QobuzRequest
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var status: NativeLinkReviewStatus

    init(link: ParsedQobuzLink) {
        id = UUID()
        originalURL = link.original
        request = link.request
        title = "\(link.request.kindName) \(link.request.id.rawValue)"
        subtitle = link.request.kindName
        status = .pending
    }

    var canonicalURL: URL { request.canonicalURL }
}
