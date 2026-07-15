import Foundation
import NativeQobuzCore

struct NativeAlbumQueueAddition {
    let added: [NativeQueueItem]
    let skipped: Int
}

struct NativeQueueRemoval {
    let removedID: UUID?
    let selectedItem: NativeQueueItem?
}

struct NativeQueueClearResult {
    let removedIDs: Set<UUID>
    let selectedItem: NativeQueueItem?
}

@MainActor
final class NativeQueueController: ObservableObject {
    @Published private(set) var items: [NativeQueueItem] = []
    @Published private(set) var selectedID: UUID?

    var selectedItem: NativeQueueItem? {
        items.first { $0.id == selectedID }
    }

    func restore(items: [NativeQueueItem], selectedID: UUID?) {
        self.items = items
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = items.first?.id
        }
    }

    @discardableResult
    func add(
        _ request: QobuzRequest,
        title: String?,
        subtitle: String?,
        artworkURL: URL?
    ) -> NativeQueueItem? {
        guard !items.contains(where: { $0.canonicalURL == request.canonicalURL }) else {
            qobuzLog.info(
                "queue",
                "Duplicate Qobuz request was not added",
                metadata: ["requestKind": request.kindName, "qobuzID": request.id.rawValue]
            )
            return nil
        }

        var item = NativeQueueItem(request: request, title: title)
        if let subtitle { item.subtitle = subtitle }
        item.artworkURL = artworkURL
        items.append(item)
        selectedID = item.id
        qobuzLog.notice(
            "queue",
            "Qobuz request added to queue",
            metadata: [
                "queueID": item.id.uuidString,
                "requestKind": request.kindName,
                "qobuzID": request.id.rawValue,
                "queueCount": String(items.count)
            ]
        )
        return item
    }

    func addAlbums(_ albums: [QobuzAlbum]) -> NativeAlbumQueueAddition {
        var knownURLs = Set(items.map(\.canonicalURL))
        var added: [NativeQueueItem] = []
        var skipped = 0

        for album in albums where album.accountAvailabilityIssue == nil {
            let request = QobuzRequest.album(album.id)
            guard knownURLs.insert(request.canonicalURL).inserted else {
                skipped += 1
                continue
            }
            var item = NativeQueueItem(request: request, title: album.displayTitle)
            item.subtitle = album.albumArtistDisplayName
            item.artworkURL = album.image?.bestURL
            added.append(item)
        }

        if !added.isEmpty {
            items.append(contentsOf: added)
            selectedID = added[0].id
            qobuzLog.notice(
                "queue",
                "Album editions added to queue",
                metadata: [
                    "addedCount": String(added.count),
                    "duplicateCount": String(skipped),
                    "queueCount": String(items.count)
                ]
            )
        }
        return NativeAlbumQueueAddition(added: added, skipped: skipped)
    }

    @discardableResult
    func select(_ id: UUID?) -> NativeQueueItem? {
        guard let id, let item = items.first(where: { $0.id == id }) else {
            selectedID = nil
            qobuzLog.debug("queue.selection", "Queue selection cleared")
            return nil
        }
        selectedID = id
        qobuzLog.debug(
            "queue.selection",
            "Queue item selected",
            metadata: [
                "queueID": id.uuidString,
                "requestKind": item.request.kindName,
                "qobuzID": item.request.id.rawValue
            ]
        )
        return item
    }

    func remove(_ id: UUID, isActive: Bool) -> NativeQueueRemoval {
        guard !isActive else {
            qobuzLog.warning("queue", "Active download could not be removed", metadata: ["queueID": id.uuidString])
            return NativeQueueRemoval(removedID: nil, selectedItem: selectedItem)
        }
        guard items.contains(where: { $0.id == id }) else {
            return NativeQueueRemoval(removedID: nil, selectedItem: selectedItem)
        }
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
        qobuzLog.notice(
            "queue",
            "Queue item removed",
            metadata: ["queueID": id.uuidString, "queueCount": String(items.count)]
        )
        return NativeQueueRemoval(removedID: id, selectedItem: selectedItem)
    }

    func clear(retaining activeIDs: Set<UUID>) -> NativeQueueClearResult {
        let before = items.count
        let removedIDs = Set(items.map(\.id)).subtracting(activeIDs)
        items.removeAll { !activeIDs.contains($0.id) }
        selectedID = items.first?.id
        qobuzLog.notice(
            "queue",
            "Inactive queue items cleared",
            metadata: [
                "removedCount": String(before - items.count),
                "retainedActiveCount": String(items.count)
            ]
        )
        return NativeQueueClearResult(removedIDs: removedIDs, selectedItem: selectedItem)
    }

    @discardableResult
    func setQuality(_ quality: QobuzQuality?, for id: UUID, mutationsAllowed: Bool) -> Bool {
        guard mutationsAllowed,
              items.first(where: { $0.id == id })?.repairTarget == nil else { return false }
        update(id) { $0.downloadQuality = quality }
        qobuzLog.info(
            "queue.plan",
            "Queue quality override changed",
            metadata: ["queueID": id.uuidString, "quality": quality?.rawValue ?? "default"]
        )
        return true
    }

    @discardableResult
    func toggleTrack(_ trackID: QobuzID, in id: UUID, mutationsAllowed: Bool) -> Bool {
        guard mutationsAllowed,
              items.first(where: { $0.id == id })?.trackPlan != nil else { return false }
        update(id) { item in
            var selected = item.effectiveSelectedTrackIDs
            if selected.contains(trackID) { selected.remove(trackID) }
            else if item.availableTrackIDs.contains(trackID) { selected.insert(trackID) }
            item.selectedTrackIDs = selected
        }
        if let item = items.first(where: { $0.id == id }) {
            qobuzLog.info(
                "queue.plan",
                "Queue track selection changed",
                metadata: [
                    "queueID": id.uuidString,
                    "trackID": trackID.rawValue,
                    "selectedTrackCount": String(item.effectiveSelectedTrackIDs.count)
                ]
            )
        }
        return true
    }

    @discardableResult
    func selectAllTracks(in id: UUID, mutationsAllowed: Bool) -> Bool {
        guard mutationsAllowed,
              items.first(where: { $0.id == id })?.trackPlan != nil else { return false }
        update(id) { $0.selectedTrackIDs = nil }
        qobuzLog.info("queue.plan", "All available queue tracks selected", metadata: ["queueID": id.uuidString])
        return true
    }

    @discardableResult
    func clearTrackSelection(in id: UUID, mutationsAllowed: Bool) -> Bool {
        guard mutationsAllowed,
              items.first(where: { $0.id == id })?.trackPlan != nil else { return false }
        update(id) { $0.selectedTrackIDs = [] }
        qobuzLog.info("queue.plan", "Queue track selection cleared", metadata: ["queueID": id.uuidString])
        return true
    }

    func move(from offsets: IndexSet, to destination: Int, mutationsAllowed: Bool) {
        guard mutationsAllowed, !offsets.isEmpty else { return }
        let moving = offsets.sorted().map { items[$0] }
        for index in offsets.sorted(by: >) { items.remove(at: index) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = min(max(destination - removedBeforeDestination, 0), items.count)
        items.insert(contentsOf: moving, at: insertion)
        qobuzLog.debug(
            "queue.order",
            "Queue items reordered",
            metadata: ["movedCount": String(moving.count), "destinationIndex": String(insertion)]
        )
    }

    func move(_ sourceID: UUID, before targetID: UUID, mutationsAllowed: Bool) {
        guard mutationsAllowed,
              sourceID != targetID,
              let source = items.firstIndex(where: { $0.id == sourceID }),
              items.contains(where: { $0.id == targetID }) else { return }
        let item = items.remove(at: source)
        guard let target = items.firstIndex(where: { $0.id == targetID }) else { return }
        items.insert(item, at: target)
    }

    func moveUp(_ id: UUID, mutationsAllowed: Bool) {
        guard mutationsAllowed,
              let index = items.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        items.swapAt(index, index - 1)
    }

    func moveDown(_ id: UUID, mutationsAllowed: Bool) {
        guard mutationsAllowed,
              let index = items.firstIndex(where: { $0.id == id }),
              index + 1 < items.count else { return }
        items.swapAt(index, index + 1)
    }

    func preflight(
        for item: NativeQueueItem,
        archiveSnapshot: QobuzArchiveSnapshot?
    ) -> NativeQueuePreflight {
        let selectedIDs = item.effectiveSelectedTrackIDs
        let selectedCount: Int?
        let unavailable: Int
        if let trackPlan = item.trackPlan {
            selectedCount = trackPlan.count { $0.isAvailable && selectedIDs.contains($0.qobuzID) }
            unavailable = trackPlan.count { !$0.isAvailable }
        } else {
            selectedCount = item.selectedTrackIDs?.count ?? item.expectedTrackIDs?.count
            unavailable = 0
        }

        var verified = 0
        var problems = 0
        if let archiveSnapshot, !selectedIDs.isEmpty {
            let albumID: QobuzID? = if case .album(let id) = item.request { id } else { nil }
            let coverage = archiveSnapshot.coverage(trackIDs: Array(selectedIDs), albumID: albumID)
            verified = coverage.verifiedCount
            problems = coverage.problemCount
        }
        return NativeQueuePreflight(
            total: item.trackPlan?.count,
            available: item.trackPlan?.filter(\.isAvailable).count,
            selected: selectedCount,
            unavailable: unavailable,
            verified: verified,
            problems: problems
        )
    }

    func update(_ id: UUID, mutate: (inout NativeQueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    func append(_ item: NativeQueueItem) {
        items.append(item)
    }

    func updateTrackPlan(
        _ id: UUID,
        tracks: [QobuzTrack],
        unavailableReason: (QobuzTrack) -> String?
    ) {
        let plan = tracks.enumerated().map { offset, track in
            NativeQueueTrack(
                id: "\(track.id.rawValue)#\(offset)",
                qobuzID: track.id,
                title: track.displayTitle,
                subtitle: track.performer?.name ?? track.album?.title ?? "Track",
                duration: track.duration,
                position: offset + 1,
                unavailableReason: unavailableReason(track)
            )
        }
        let available = Set(plan.filter(\.isAvailable).map(\.qobuzID))
        update(id) { item in
            item.trackPlan = plan
            item.expectedTrackIDs = plan.filter(\.isAvailable).map(\.qobuzID)
            if var selected = item.selectedTrackIDs {
                selected.formIntersection(available)
                item.selectedTrackIDs = selected
            }
        }
    }

    func updateMetadata(_ id: UUID, title: String, subtitle: String, artworkURL: URL? = nil) {
        update(id) { item in
            item.title = title
            item.subtitle = subtitle
            if let artworkURL { item.artworkURL = artworkURL }
        }
    }
}
