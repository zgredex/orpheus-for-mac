import Foundation
import NativeQobuzCore

struct NativeQueueItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let request: QobuzRequest
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var expectedTrackIDs: [QobuzID]?
    var repairTarget: QobuzArchiveTrack?
    var downloadQuality: QobuzQuality?
    /// Metadata used by the queue inspector. `nil` until the item has been resolved.
    var trackPlan: [NativeQueueTrack]?
    /// `nil` means every available track. An empty set intentionally blocks starting.
    var selectedTrackIDs: Set<QobuzID>?

    var canonicalURL: URL { request.canonicalURL }

    var availableTrackIDs: Set<QobuzID> {
        if let trackPlan {
            return Set(trackPlan.filter(\.isAvailable).map(\.qobuzID))
        }
        return Set(expectedTrackIDs ?? [])
    }

    var effectiveSelectedTrackIDs: Set<QobuzID> {
        selectedTrackIDs ?? availableTrackIDs
    }

    var hasSelectedTracks: Bool {
        if repairTarget != nil { return true }
        if selectedTrackIDs != nil { return !effectiveSelectedTrackIDs.isEmpty }
        // Artist and label plans are resolved by the engine at the front of the queue.
        return trackPlan == nil || !availableTrackIDs.isEmpty
    }

    init(request: QobuzRequest, title: String? = nil) {
        id = UUID()
        self.request = request
        self.title = title ?? "\(request.kindName) \(request.id.rawValue)"
        subtitle = request.kindName
        repairTarget = nil
        if case .track(let id) = request {
            expectedTrackIDs = [id]
        }
    }

    init(repairTarget: QobuzArchiveTrack) {
        id = UUID()
        request = .track(QobuzID(repairTarget.qobuzTrackID))
        title = URL(fileURLWithPath: repairTarget.relativePath).lastPathComponent
        subtitle = "Repair · \(repairTarget.audioFormat?.displayName ?? "Format \(repairTarget.formatID)")"
        expectedTrackIDs = [QobuzID(repairTarget.qobuzTrackID)]
        self.repairTarget = repairTarget
        // Repairs use the archive's exact format, not the user's maximum policy.
        downloadQuality = nil
    }
}

struct NativeQueueTrack: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let qobuzID: QobuzID
    let title: String
    let subtitle: String
    let duration: Int?
    let position: Int
    let unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }
}

struct NativeQueuePreflight: Equatable, Sendable {
    let total: Int?
    let available: Int?
    let selected: Int?
    let unavailable: Int
    let verified: Int
    let problems: Int

    var needsDownload: Int? {
        selected.map { max($0 - verified, 0) }
    }
}
