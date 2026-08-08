import Foundation

/// Bounds progress-event production before events enter the public download
/// stream. This prevents a fast network callback queue from retaining thousands
/// of obsolete UI updates when the main actor is busy.
struct QobuzDownloadProgressLimiter {
    private let minimumInterval: TimeInterval
    private let minimumFractionDelta: Double
    private let now: () -> TimeInterval
    private var lastEmissionTime: TimeInterval?
    private var lastFraction: Double?

    init(
        minimumInterval: TimeInterval = 0.1,
        minimumFractionDelta: Double = 0.01,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.minimumInterval = minimumInterval
        self.minimumFractionDelta = minimumFractionDelta
        self.now = now
    }

    mutating func shouldEmit(fraction: Double?) -> Bool {
        let currentTime = now()
        let isTerminal = fraction.map { $0 >= 1 } ?? false
        let crossedFractionBoundary = if let fraction, let lastFraction {
            fraction - lastFraction >= minimumFractionDelta
        } else {
            false
        }
        let intervalElapsed = lastEmissionTime.map {
            currentTime - $0 >= minimumInterval
        } ?? true
        guard isTerminal || crossedFractionBoundary || intervalElapsed else { return false }
        lastEmissionTime = currentTime
        lastFraction = fraction
        return true
    }
}
