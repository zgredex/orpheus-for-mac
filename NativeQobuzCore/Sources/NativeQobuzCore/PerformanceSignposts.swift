import Foundation
import OSLog

/// Stable Instruments points for the expensive paths guarded by CI budgets.
/// Structured JSONL diagnostics remain the source for failure detail; these
/// intervals expose duration and nesting without adding high-frequency events.
public enum QobuzPerformanceSignposts {
    public struct Interval {
        fileprivate let name: StaticString
        fileprivate let id: OSSignpostID
    }

    private static let log = OSLog(
        subsystem: "com.orpheus.formac",
        category: .pointsOfInterest
    )

    public static func begin(
        _ name: StaticString,
        metadata: String = ""
    ) -> Interval {
        let id = OSSignpostID(log: log)
        os_signpost(
            .begin,
            log: log,
            name: name,
            signpostID: id,
            "%{public}@",
            metadata as NSString
        )
        return Interval(name: name, id: id)
    }

    public static func end(
        _ interval: Interval,
        metadata: String = ""
    ) {
        os_signpost(
            .end,
            log: log,
            name: interval.name,
            signpostID: interval.id,
            "%{public}@",
            metadata as NSString
        )
    }
}
