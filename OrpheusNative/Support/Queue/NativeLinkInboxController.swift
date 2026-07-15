import Foundation
import NativeQobuzCore

struct NativeLinkInboxAddition {
    let addedCount: Int
    let duplicateOnly: Bool
    let requiresConfiguration: Bool
}

@MainActor
final class NativeLinkInboxController: ObservableObject {
    @Published private(set) var items: [NativeLinkInboxItem] = []

    private var client: (any NativeQobuzServicing)?
    private var availabilityPolicy = NativeCatalogAvailabilityPolicy(accountRegion: nil)
    private var reviewTask: Task<Void, Never>?

    func configure(client: (any NativeQobuzServicing)?, accountRegion: String?) {
        self.client = client
        availabilityPolicy.accountRegion = accountRegion
    }

    func restore(_ items: [NativeLinkInboxItem]) {
        reviewTask?.cancel()
        reviewTask = nil
        self.items = items
    }

    func item(_ id: UUID) -> NativeLinkInboxItem? {
        items.first { $0.id == id }
    }

    func add(_ links: [ParsedQobuzLink]) -> NativeLinkInboxAddition {
        let known = Set(items.map { $0.canonicalURL.absoluteString })
        var seen = known
        let newItems = links.compactMap { link -> NativeLinkInboxItem? in
            guard seen.insert(link.canonicalURL.absoluteString).inserted else { return nil }
            return NativeLinkInboxItem(link: link)
        }
        guard !newItems.isEmpty else {
            return NativeLinkInboxAddition(
                addedCount: 0,
                duplicateOnly: true,
                requiresConfiguration: false
            )
        }
        items.append(contentsOf: newItems)
        let requiresConfiguration = review(newItems.map { ($0.id, $0.request) })
        return NativeLinkInboxAddition(
            addedCount: newItems.count,
            duplicateOnly: false,
            requiresConfiguration: requiresConfiguration
        )
    }

    @discardableResult
    func retry(_ id: UUID) -> Bool {
        guard let item = item(id) else { return false }
        return review([(item.id, item.request)])
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clearReviewed() {
        items.removeAll { $0.status.isReviewed }
    }

    func clear() {
        cancel()
        items.removeAll()
    }

    func cancel() {
        reviewTask?.cancel()
        reviewTask = nil
    }

    @discardableResult
    private func review(_ requested: [(UUID, QobuzRequest)]) -> Bool {
        guard let client else {
            for (id, _) in requested {
                update(id) { $0.status = .failed("Configure Qobuz credentials to verify this link.") }
            }
            return true
        }

        reviewTask?.cancel()
        var workByID = Dictionary(uniqueKeysWithValues: requested.map { ($0.0, $0.1) })
        for item in items {
            switch item.status {
            case .pending, .checking:
                workByID[item.id] = item.request
            default:
                break
            }
        }
        let work = items.compactMap { item in
            workByID[item.id].map { (item.id, $0) }
        }
        for (id, _) in work { update(id) { $0.status = .checking } }

        reviewTask = Task { [weak self] in
            await withTaskGroup(of: NativeInboxReviewResult.self) { group in
                var next = 0
                let limit = min(3, work.count)
                for _ in 0..<limit {
                    let value = work[next]
                    next += 1
                    group.addTask {
                        await Self.fetchReview(id: value.0, request: value.1, client: client)
                    }
                }
                while let result = await group.next() {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(result)
                    if next < work.count {
                        let value = work[next]
                        next += 1
                        group.addTask {
                            await Self.fetchReview(id: value.0, request: value.1, client: client)
                        }
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.reviewTask = nil
        }
        return false
    }

    private static func fetchReview(
        id: UUID,
        request: QobuzRequest,
        client: any NativeQobuzServicing
    ) async -> NativeInboxReviewResult {
        do {
            let payload: NativeInboxReviewPayload
            switch request {
            case .album(let value): payload = .album(try await client.album(id: value))
            case .artist(let value): payload = .artist(try await client.artist(id: value))
            case .track(let value): payload = .track(try await client.track(id: value))
            case .playlist(let value): payload = .playlist(try await client.playlist(id: value))
            case .label(let value): payload = .label(try await client.label(id: value))
            }
            return NativeInboxReviewResult(id: id, payload: payload, failure: nil)
        } catch let error as NativeQobuzError {
            return NativeInboxReviewResult(id: id, payload: nil, failure: .qobuz(error))
        } catch {
            return NativeInboxReviewResult(id: id, payload: nil, failure: .other(error.localizedDescription))
        }
    }

    private func apply(_ result: NativeInboxReviewResult) {
        guard let payload = result.payload else {
            let status: NativeLinkReviewStatus
            switch result.failure {
            case .qobuz(let error):
                let message = availabilityPolicy.errorMessage(error)
                switch error {
                case .unavailable, .emptyCollection:
                    status = .unavailable(message)
                default:
                    status = .failed(message)
                }
            case .other(let message):
                status = .failed(message)
            case nil:
                status = .failed("Could not verify this Qobuz link.")
            }
            update(result.id) { $0.status = status }
            return
        }

        let values: (title: String, subtitle: String, artwork: URL?, availability: NativeBrowseAvailability)
        switch payload {
        case .album(let value):
            values = (
                value.displayTitle,
                value.mainArtists.map(\.name).joined(separator: ", "),
                value.image?.bestURL,
                availabilityPolicy.availability(for: value)
            )
        case .artist(let value):
            values = (
                value.name,
                "\(value.officialAlbums.count) official releases",
                value.image?.bestURL,
                availabilityPolicy.availability(for: value)
            )
        case .track(let value):
            values = (
                value.displayTitle,
                value.performer?.name ?? value.album?.title ?? "Track",
                value.album?.image?.bestURL,
                availabilityPolicy.availability(for: value)
            )
        case .playlist(let value):
            values = (
                value.name,
                [value.owner?.name, "\(value.availableTracks.count) available tracks"]
                    .compactMap { $0 }.joined(separator: " · "),
                value.artworkURL,
                availabilityPolicy.availability(for: value)
            )
        case .label(let value):
            values = (
                value.name,
                "\(value.availableAlbums.count) available albums",
                nil,
                availabilityPolicy.availability(for: value)
            )
        }
        update(result.id) { item in
            item.title = values.title
            item.subtitle = values.subtitle
            item.artworkURL = values.artwork
            item.status = Self.reviewStatus(for: values.availability)
        }
    }

    private func update(_ id: UUID, mutate: (inout NativeLinkInboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    private static func reviewStatus(for availability: NativeBrowseAvailability) -> NativeLinkReviewStatus {
        switch availability {
        case .checking: .checking
        case .available: .available
        case .partial(let message): .partial(message)
        case .unavailable(let message): .unavailable(message)
        }
    }
}

private enum NativeInboxReviewPayload: Sendable {
    case album(QobuzAlbum)
    case artist(QobuzArtistCatalog)
    case track(QobuzTrack)
    case playlist(QobuzPlaylist)
    case label(QobuzLabelCatalog)
}

private struct NativeInboxReviewResult: Sendable {
    let id: UUID
    let payload: NativeInboxReviewPayload?
    let failure: NativeInboxReviewFailure?
}

private enum NativeInboxReviewFailure: Sendable {
    case qobuz(NativeQobuzError)
    case other(String)
}
