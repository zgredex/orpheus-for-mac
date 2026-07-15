import Foundation
import NativeQobuzCore

enum NativeNoticeMutation {
    case unchanged
    case set(String?)
}

@MainActor
final class NativeQueueOrchestrator {
    private let queue: NativeQueueController
    private let preview: NativePreviewController
    private let downloads: NativeDownloadController

    init(
        queue: NativeQueueController,
        preview: NativePreviewController,
        downloads: NativeDownloadController
    ) {
        self.queue = queue
        self.preview = preview
        self.downloads = downloads
    }

    func selectedTrackIDs(for request: QobuzRequest) -> Set<QobuzID>? {
        guard let item = queue.selectedItem,
              item.request == request,
              item.trackPlan != nil else { return nil }
        return item.effectiveSelectedTrackIDs
    }

    func toggleSelectedTrack(_ trackID: QobuzID, mutationsAllowed: Bool) {
        guard let id = queue.selectedID else { return }
        toggleTrack(trackID, in: id, mutationsAllowed: mutationsAllowed)
    }

    func selectAllSelectedTracks(mutationsAllowed: Bool) {
        guard let id = queue.selectedID else { return }
        selectAllTracks(in: id, mutationsAllowed: mutationsAllowed)
    }

    func clearSelectedTracks(mutationsAllowed: Bool) {
        guard let id = queue.selectedID else { return }
        clearTrackSelection(in: id, mutationsAllowed: mutationsAllowed)
    }

    func addRequest(
        _ request: QobuzRequest,
        title: String?,
        subtitle: String?,
        artworkURL: URL?,
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) -> NativeNoticeMutation {
        guard let item = queue.add(request, title: title, subtitle: subtitle, artworkURL: artworkURL) else {
            return .set("That Qobuz item is already queued.")
        }
        downloads.registerQueue(item.id)
        loadPreview(item, client: client, unavailabilityMessage: unavailabilityMessage)
        return .unchanged
    }

    func addAlbums(
        _ albums: [QobuzAlbum],
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) -> NativeNoticeMutation {
        let result = queue.addAlbums(albums)
        guard !result.added.isEmpty else {
            return result.skipped > 0 ? .set("Those editions are already queued.") : .unchanged
        }
        downloads.registerQueues(result.added.map(\.id))
        loadPreview(result.added[0], client: client, unavailabilityMessage: unavailabilityMessage)
        if result.skipped > 0 {
            let noun = result.skipped == 1 ? "edition" : "editions"
            return .set("Skipped \(result.skipped) already queued \(noun).")
        }
        return .set(nil)
    }

    func select(
        _ id: UUID?,
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) {
        guard let item = queue.select(id) else {
            preview.clear()
            return
        }
        loadPreview(item, client: client, unavailabilityMessage: unavailabilityMessage)
    }

    func remove(
        _ id: UUID,
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) {
        let result = queue.remove(id, isActive: downloads.status(forQueueID: id).isActive)
        guard result.removedID != nil else { return }
        downloads.removeQueue(id)
        present(result.selectedItem, client: client, unavailabilityMessage: unavailabilityMessage)
    }

    func clear(
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) {
        let activeIDs = Set(queue.items.filter { downloads.status(for: $0).isActive }.map(\.id))
        let result = queue.clear(retaining: activeIDs)
        for id in result.removedIDs { downloads.removeQueue(id) }
        present(result.selectedItem, client: client, unavailabilityMessage: unavailabilityMessage)
    }

    func setQuality(_ quality: QobuzQuality?, for id: UUID, mutationsAllowed: Bool) {
        guard queue.setQuality(quality, for: id, mutationsAllowed: mutationsAllowed) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func toggleTrack(_ trackID: QobuzID, in id: UUID, mutationsAllowed: Bool) {
        guard queue.toggleTrack(trackID, in: id, mutationsAllowed: mutationsAllowed) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func selectAllTracks(in id: UUID, mutationsAllowed: Bool) {
        guard queue.selectAllTracks(in: id, mutationsAllowed: mutationsAllowed) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func clearTrackSelection(in id: UUID, mutationsAllowed: Bool) {
        guard queue.clearTrackSelection(in: id, mutationsAllowed: mutationsAllowed) else { return }
        downloads.resetAfterPlanChange(id)
    }

    func loadPreview(
        _ item: NativeQueueItem,
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) {
        preview.load(
            item,
            client: client,
            onResolved: { [weak self] resolution in
                guard let self else { return }
                queue.updateMetadata(
                    resolution.queueID,
                    title: resolution.title,
                    subtitle: resolution.subtitle,
                    artworkURL: resolution.artworkURL
                )
                if let tracks = resolution.tracks {
                    queue.updateTrackPlan(resolution.queueID, tracks: tracks, unavailableReason: unavailabilityMessage)
                }
            },
            onFailure: { [weak self] message in
                self?.downloads.markFailed(queueID: item.id, message: message)
            }
        )
    }

    private func present(
        _ item: NativeQueueItem?,
        client: (any NativeQobuzServicing)?,
        unavailabilityMessage: @escaping (QobuzTrack) -> String?
    ) {
        if let item {
            loadPreview(item, client: client, unavailabilityMessage: unavailabilityMessage)
        } else {
            preview.clear()
        }
    }
}
