import Foundation
import NativeQobuzCore
import Network

enum NativeConnectivityState: String, Equatable, Sendable {
    case unknown
    case online
    case offline
}

@MainActor
protocol NativeConnectivityMonitoring: AnyObject {
    var state: NativeConnectivityState { get }
    func start(onChange: @escaping @MainActor (NativeConnectivityState) -> Void)
    func stop()
}

@MainActor
final class NativeNetworkConnectivityMonitor: NativeConnectivityMonitoring {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var handler: (@MainActor (NativeConnectivityState) -> Void)?
    private(set) var state: NativeConnectivityState = .unknown
    private var started = false

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "com.orpheus.native.network-path")
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    func start(onChange: @escaping @MainActor (NativeConnectivityState) -> Void) {
        handler = onChange
        guard !started else {
            onChange(state)
            return
        }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next: NativeConnectivityState = path.status == .satisfied ? .online : .offline
            Task { @MainActor [weak self] in
                guard let self, self.state != next else { return }
                self.state = next
                self.handler?(next)
            }
        }
        monitor.start(queue: queue)
        qobuzLog.info("network.monitor", "Network path monitoring started")
    }

    func stop() {
        guard started else { return }
        started = false
        handler = nil
        monitor.cancel()
        qobuzLog.info("network.monitor", "Network path monitoring stopped")
    }
}

@MainActor
protocol NativePowerActivityManaging: AnyObject {
    func begin(reason: String) -> NSObjectProtocol
    func end(_ token: NSObjectProtocol)
}

@MainActor
final class NativePowerActivityManager: NativePowerActivityManaging {
    private let processInfo: ProcessInfo

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    func begin(reason: String) -> NSObjectProtocol {
        let token = processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: reason
        )
        qobuzLog.info("power.activity", "System sleep prevention began", metadata: ["reason": reason])
        return token
    }

    func end(_ token: NSObjectProtocol) {
        processInfo.endActivity(token)
        qobuzLog.info("power.activity", "System sleep prevention ended")
    }
}

@MainActor
func withNativePowerActivity<Value>(
    using manager: any NativePowerActivityManaging,
    reason: String,
    operation: () async throws -> Value
) async rethrows -> Value {
    let token = manager.begin(reason: reason)
    defer { manager.end(token) }
    return try await operation()
}

enum NativeConnectivityRecoveryAction: Equatable {
    case retryNow
    case waitForChange(afterGeneration: UInt64)
}

/// Allows one immediate signed-URL refresh when the system path already looks
/// healthy. A repeated failure waits for a path event or the view model's
/// delayed fallback probe, preventing both tight loops and permanent stalls.
struct NativeConnectivityRecoveryPolicy: Equatable {
    private(set) var usedImmediateRetry = false

    mutating func action(
        state: NativeConnectivityState,
        generation: UInt64
    ) -> NativeConnectivityRecoveryAction {
        if state == .online, !usedImmediateRetry {
            usedImmediateRetry = true
            return .retryNow
        }
        return .waitForChange(afterGeneration: generation)
    }

    mutating func recovered() {
        usedImmediateRetry = false
    }
}

/// Grants one signed-URL refresh to each failing track. Qobuz URLs expire per
/// media request, so spending one album-wide retry must not strand later tracks.
struct NativeSignedURLRecoveryBudget: Equatable {
    private var refreshedTrackIDs: Set<QobuzID> = []
    private var usedUnscopedRetry = false

    @discardableResult
    mutating func consume(for trackID: QobuzID?) -> Bool {
        guard let trackID else {
            guard !usedUnscopedRetry else { return false }
            usedUnscopedRetry = true
            return true
        }
        return refreshedTrackIDs.insert(trackID).inserted
    }

    mutating func reset() {
        refreshedTrackIDs.removeAll(keepingCapacity: true)
        usedUnscopedRetry = false
    }
}
