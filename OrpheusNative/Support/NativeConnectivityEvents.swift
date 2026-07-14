import Foundation
import NativeQobuzCore

struct NativeConnectivityEvent: Sendable {
    let state: NativeConnectivityState
    let generation: UInt64
}

/// Event fan-out for connectivity recovery. Each waiter receives path changes
/// without polling, and its stream is removed automatically on cancellation.
@MainActor
final class NativeConnectivityEvents {
    private var continuations: [UUID: AsyncStream<NativeConnectivityEvent>.Continuation] = [:]

    func stream() -> AsyncStream<NativeConnectivityEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func publish(state: NativeConnectivityState, generation: UInt64) {
        let event = NativeConnectivityEvent(state: state, generation: generation)
        for continuation in continuations.values { continuation.yield(event) }
    }

    /// Waits for a real path transition, while periodically allowing a signed-
    /// URL retry when the system path stays online after DNS or proxy recovery.
    func waitForOnline(
        after generation: UInt64,
        fallbackDelay: Duration = .seconds(5),
        currentState: @escaping @MainActor @Sendable () -> NativeConnectivityState
    ) async throws {
        let events = stream()
        var probeTask: Task<Void, Never>?
        defer { probeTask?.cancel() }

        func scheduleFallbackProbe() {
            probeTask?.cancel()
            probeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: fallbackDelay)
                guard !Task.isCancelled, let self else { return }
                self.publish(state: currentState(), generation: generation)
            }
        }

        scheduleFallbackProbe()
        for await event in events {
            try Task.checkCancellation()
            if event.state == .online,
               event.generation > generation || currentState() == .online {
                return
            }
            scheduleFallbackProbe()
        }
        throw NativeQobuzError.cancelled
    }
}
