import Foundation
import NativeQobuzCore

struct NativeQueuePreviewResolution {
    let queueID: UUID
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let tracks: [QobuzTrack]?
}

@MainActor
final class NativePreviewController: ObservableObject {
    @Published private(set) var state: NativePreviewState = .empty

    private var task: Task<Void, Never>?
    private var loadID: UUID?

    func clear() {
        cancel()
        state = .empty
    }

    func cancel() {
        task?.cancel()
        task = nil
        loadID = nil
    }

    func load(
        _ item: NativeQueueItem,
        client: (any NativeQobuzServicing)?,
        onResolved: @escaping @MainActor (NativeQueuePreviewResolution) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        cancel()
        guard let client else {
            qobuzLog.warning(
                "queue.preview",
                "Queue preview blocked because credentials are not configured",
                metadata: ["queueID": item.id.uuidString]
            )
            state = .error("Configure Qobuz credentials to load metadata.")
            return
        }

        state = .loading
        let currentLoadID = UUID()
        loadID = currentLoadID
        let metadata = [
            "previewLoadID": currentLoadID.uuidString,
            "queueID": item.id.uuidString,
            "requestKind": item.request.kindName,
            "qobuzID": item.request.id.rawValue
        ]
        qobuzLog.info("queue.preview", "Queue preview loading started", metadata: metadata)

        task = Task { [weak self] in
            do {
                let result: (NativePreviewState, NativeQueuePreviewResolution)
                result = try await QobuzLogScope.withValue(metadata) {
                    switch item.request {
                    case .album(let id):
                        let value = try await client.album(id: id)
                        return (
                            .album(value),
                            NativeQueuePreviewResolution(
                                queueID: item.id,
                                title: value.displayTitle,
                                subtitle: value.albumArtistDisplayName,
                                artworkURL: value.image?.bestURL,
                                tracks: value.tracks
                            )
                        )
                    case .track(let id):
                        let value = try await client.track(id: id)
                        return (
                            .track(value),
                            NativeQueuePreviewResolution(
                                queueID: item.id,
                                title: value.displayTitle,
                                subtitle: value.performer?.name ?? "Track",
                                artworkURL: value.album?.image?.bestURL,
                                tracks: [value]
                            )
                        )
                    case .playlist(let id):
                        let value = try await client.playlist(id: id)
                        return (
                            .playlist(value),
                            NativeQueuePreviewResolution(
                                queueID: item.id,
                                title: value.name,
                                subtitle: [value.owner?.name, "\(value.availableTracks.count) available tracks"]
                                    .compactMap { $0 }.joined(separator: " · "),
                                artworkURL: value.artworkURL,
                                tracks: value.tracks
                            )
                        )
                    case .artist(let id):
                        let value = try await client.artist(id: id)
                        let count = value.officialAlbums.count
                        return (
                            .artist(value),
                            NativeQueuePreviewResolution(
                                queueID: item.id,
                                title: value.name,
                                subtitle: "\(count) official \(count == 1 ? "release" : "releases")",
                                artworkURL: value.image?.bestURL,
                                tracks: nil
                            )
                        )
                    case .label(let id):
                        let value = try await client.label(id: id)
                        let count = value.availableAlbums.count
                        return (
                            .label(value),
                            NativeQueuePreviewResolution(
                                queueID: item.id,
                                title: value.name,
                                subtitle: "\(count) available \(count == 1 ? "album" : "albums")",
                                artworkURL: nil,
                                tracks: nil
                            )
                        )
                    }
                }
                guard let self,
                      !Task.isCancelled,
                      loadID == currentLoadID else { return }
                state = result.0
                task = nil
                loadID = nil
                onResolved(result.1)
                qobuzLog.info("queue.preview", "Queue preview loaded", metadata: metadata)
            } catch let error where error.isQobuzCancellation {
                qobuzLog.debug("queue.preview", "Queue preview load cancelled", metadata: metadata)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      loadID == currentLoadID else { return }
                state = .error(error.localizedDescription)
                task = nil
                loadID = nil
                qobuzLog.error("queue.preview", "Queue preview failed to load", metadata: metadata, error: error)
                onFailure(error.localizedDescription)
            }
        }
    }
}
