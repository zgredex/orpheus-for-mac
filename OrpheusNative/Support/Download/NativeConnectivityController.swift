import Combine
import Foundation
import NativeQobuzCore

@MainActor
final class NativeConnectivityController: ObservableObject {
    @Published private(set) var state: NativeConnectivityState = .unknown
    private(set) var generation: UInt64 = 0

    private let monitor: any NativeConnectivityMonitoring
    private let events = NativeConnectivityEvents()

    init(monitor: any NativeConnectivityMonitoring) {
        self.monitor = monitor
    }

    func start() {
        monitor.start { [weak self] state in
            self?.apply(state)
        }
    }

    func stop() {
        monitor.stop()
    }

    func waitForOnline(after generation: UInt64) async throws {
        qobuzLog.info(
            "download.recovery.network",
            "Waiting for a satisfied network path",
            metadata: [
                "connectivity": state.rawValue,
                "afterGeneration": String(generation)
            ]
        )
        try await events.waitForOnline(after: generation) { [weak self] in
            self?.state ?? .unknown
        }
    }

    private func apply(_ state: NativeConnectivityState) {
        guard self.state != state else { return }
        let previous = self.state
        self.state = state
        generation &+= 1
        events.publish(state: state, generation: generation)
        qobuzLog.notice(
            "network.path",
            "Network path state changed",
            metadata: [
                "previous": previous.rawValue,
                "current": state.rawValue,
                "generation": String(generation)
            ]
        )
    }
}
