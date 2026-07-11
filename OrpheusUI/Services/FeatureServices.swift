import Foundation

struct QueueStateService {
    @discardableResult
    func clearInactive(queue: inout [QueuedLink], selectedID: inout UUID?) -> Int {
        let removedIDs = Set(queue.filter { !$0.state.isActive }.map(\.id))
        guard !removedIDs.isEmpty else { return 0 }

        queue.removeAll { removedIDs.contains($0.id) }
        if selectedID.map(removedIDs.contains) == true || selectedID == nil {
            selectedID = queue.first?.id
        }
        return removedIDs.count
    }

    func remove(id: UUID, queue: inout [QueuedLink], selectedID: inout UUID?) {
        queue.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = queue.first?.id
        }
    }

    func setState(
        id: UUID,
        state: QueueItemState,
        downloadID: UUID? = nil,
        queue: inout [QueuedLink]
    ) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].state = state
        if let downloadID {
            queue[index].downloadID = downloadID
        }
    }
}

struct DownloadMutation {
    var status: DownloadStatus?
    var phase: DownloadPhase?
    var progress: Double?
    var speed: String?
    var downloaded: String?
    var total: String?
    var completedUnits: Int?
    var totalUnits: Int?
    var resolvedOutputURL: URL?
    var resetTransfer = false
    var clearSpeed = false
}

struct DownloadStateReducer {
    func apply(_ mutation: DownloadMutation, to downloads: inout [DownloadItem], id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        if mutation.resetTransfer {
            downloads[index].speed = nil
            downloads[index].downloaded = nil
            downloads[index].total = nil
        }
        if let status = mutation.status { downloads[index].status = status }
        if let phase = mutation.phase { downloads[index].phase = phase }
        if let progress = mutation.progress {
            downloads[index].progress = DownloadItem.clampedFraction(progress)
        }
        if mutation.clearSpeed { downloads[index].speed = nil }
        if let speed = mutation.speed { downloads[index].speed = speed }
        if let downloaded = mutation.downloaded { downloads[index].downloaded = downloaded }
        if let total = mutation.total { downloads[index].total = total }
        if let completedUnits = mutation.completedUnits { downloads[index].completedUnits = completedUnits }
        if let totalUnits = mutation.totalUnits { downloads[index].totalUnits = totalUnits }
        if let resolvedOutputURL = mutation.resolvedOutputURL {
            downloads[index].resolvedOutputURL = resolvedOutputURL
        }
    }
}

struct BrowseAlbumResolution {
    let albums: [QobuzAlbumResponse]
    let unavailableCount: Int
}

struct BrowseAlbumResolver {
    func resolve(
        _ albums: [QobuzAlbumResponse],
        query: String,
        api: QobuzServicing
    ) async -> BrowseAlbumResolution {
        var resolved: [QobuzAlbumResponse] = []
        var seenIDs = Set<String>()
        var unavailableCount = 0
        var trackCandidates: [QobuzTrackResponse]?

        for album in albums {
            if album.isBrowseAvailable {
                append(album, to: &resolved, seenIDs: &seenIDs)
                continue
            }

            if trackCandidates == nil {
                trackCandidates = (try? await api.search(query: query, type: .track, limit: 30).tracks?.items) ?? []
            }

            if let equivalent = await availableEquivalent(
                for: album,
                trackCandidates: trackCandidates ?? [],
                api: api
            ) {
                append(equivalent, to: &resolved, seenIDs: &seenIDs)
            } else {
                unavailableCount += 1
            }
        }

        return BrowseAlbumResolution(albums: resolved, unavailableCount: unavailableCount)
    }

    private func availableEquivalent(
        for unavailableAlbum: QobuzAlbumResponse,
        trackCandidates: [QobuzTrackResponse],
        api: QobuzServicing
    ) async -> QobuzAlbumResponse? {
        guard let match = trackCandidates.first(where: { track in
            track.isBrowseAvailable && matches(album: unavailableAlbum, track: track)
        }) else {
            return nil
        }

        guard let album = try? await api.getAlbum(id: match.album.id.value),
              album.isBrowseAvailable,
              album.tracks?.items.isEmpty == false else {
            return nil
        }
        return album
    }

    private func matches(album: QobuzAlbumResponse, track: QobuzTrackResponse) -> Bool {
        let targetTitle = normalized(album.title)
        guard targetTitle == normalized(track.album.title) else { return false }

        let targetArtist = normalized(album.artist.name)
        let candidateArtists = [track.performer?.name, track.album.artist?.name]
            .compactMap { $0 }
            .map(normalized)
            .filter { !$0.isEmpty }
        return candidateArtists.contains(targetArtist)
    }

    private func append(
        _ album: QobuzAlbumResponse,
        to albums: inout [QobuzAlbumResponse],
        seenIDs: inout Set<String>
    ) {
        guard seenIDs.insert(album.id.value).inserted else { return }
        albums.append(album)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
