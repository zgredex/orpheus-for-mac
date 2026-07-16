import Foundation

struct QobuzRetryDelay: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case retryAfter
        case exponentialBackoff
    }

    let duration: Duration
    let source: Source
}

/// Computes server-aware retry delays and owns the cancellation boundary around
/// sleeping. The transport remains responsible only for HTTP request attempts.
struct QobuzRetryScheduler: Sendable {
    private let policy: QobuzRetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double

    init(
        policy: QobuzRetryPolicy,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date,
        jitter: @escaping @Sendable () -> Double
    ) {
        self.policy = policy
        self.sleep = sleep
        self.now = now
        self.jitter = jitter
    }

    func delay(attempt: Int, response: HTTPURLResponse?) -> QobuzRetryDelay {
        if let value = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = retryAfterSeconds(value) {
            return QobuzRetryDelay(
                duration: duration(seconds: serverDelay(seconds)),
                source: .retryAfter
            )
        }
        let multiplier = Double(1 << min(max(attempt, 0), 8))
        let base = seconds(policy.baseDelay) * multiplier
        let factor = 1 + ((clampedJitter * 2) - 1) * policy.jitterFraction
        return QobuzRetryDelay(
            duration: duration(seconds: min(max(base * factor, 0), maximumSeconds)),
            source: .exponentialBackoff
        )
    }

    func wait(_ delay: QobuzRetryDelay) async throws {
        try Task.checkCancellation()
        try await sleep(delay.duration)
        try Task.checkCancellation()
    }

    private func serverDelay(_ advertised: TimeInterval) -> TimeInterval {
        let nonnegative = max(advertised, 0)
        let withJitter = nonnegative * (1 + clampedJitter * policy.jitterFraction)
        return min(withJitter, maximumSeconds)
    }

    private var clampedJitter: Double { min(max(jitter(), 0), 1) }
    private var maximumSeconds: Double { max(seconds(policy.maximumRetryAfter), 0) }

    private func retryAfterSeconds(_ value: String) -> TimeInterval? {
        if let seconds = Double(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now()))
            }
        }
        return nil
    }

    private func seconds(_ value: Duration) -> Double {
        let components = value.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func duration(seconds: Double) -> Duration {
        .milliseconds(Int64((seconds * 1_000).rounded()))
    }
}
