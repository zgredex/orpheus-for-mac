import Combine
import Foundation

enum NativeAppStartupState: Equatable {
    case idle
    case starting
    case ready
    case failed
    case terminating
}

/// Owns the app's startup boundary and the external URL events that may arrive
/// before persisted state has finished restoring.
@MainActor
final class NativeStartupGate: ObservableObject {
    @Published private(set) var state: NativeAppStartupState = .idle

    private var startupID: UUID?
    private var pendingOpenURLs: [URL] = []

    var isReady: Bool { state == .ready }
    var isStarting: Bool { state == .idle || state == .starting }
    var canRetry: Bool { state == .failed }
    var canEditConfiguration: Bool { state == .ready || state == .failed }

    func begin() -> UUID? {
        guard state == .idle || state == .failed else { return nil }
        let id = UUID()
        startupID = id
        state = .starting
        return id
    }

    func isCurrent(_ id: UUID) -> Bool {
        startupID == id && state == .starting
    }

    func complete(_ id: UUID) -> [URL]? {
        guard isCurrent(id) else { return nil }
        startupID = nil
        state = .ready
        defer { pendingOpenURLs.removeAll(keepingCapacity: false) }
        return pendingOpenURLs
    }

    func fail(_ id: UUID) {
        guard isCurrent(id) else { return }
        startupID = nil
        state = .failed
    }

    func beginTermination() {
        startupID = nil
        pendingOpenURLs.removeAll(keepingCapacity: false)
        state = .terminating
    }

    /// Returns true when the URL can be handled immediately. URLs received
    /// during startup or after a retryable failure are retained in order.
    func shouldHandleOpenURL(_ url: URL) -> Bool {
        switch state {
        case .ready:
            return true
        case .idle, .starting, .failed:
            pendingOpenURLs.append(url)
            return false
        case .terminating:
            return false
        }
    }
}
