import Foundation

/// One overflow-safe cursor policy for Qobuz search and collection pages.
/// Cursor advancement always follows raw server items consumed, never the
/// smaller number of presentation items that survived tolerant decoding.
public enum QobuzPageCursor {
    /// Missing or malformed cursor metadata is tolerated because the request
    /// itself is authoritative. A concrete, different offset is not: merging
    /// that response would silently skip or duplicate a page.
    public static func validatedOffset(
        reportedOffset: Int?,
        requestedOffset: Int
    ) throws -> Int {
        guard requestedOffset >= 0 else {
            throw NativeQobuzError.invalidResponse("The requested Qobuz page offset was invalid.")
        }
        if let reportedOffset, reportedOffset != requestedOffset {
            throw NativeQobuzError.invalidResponse(
                "Qobuz returned page offset \(reportedOffset) for requested offset \(requestedOffset)."
            )
        }
        return requestedOffset
    }

    public static func nextOffset(
        reportedOffset: Int?,
        requestedOffset: Int,
        rawItemCount: Int,
        total: Int?,
        requestedLimit: Int
    ) -> Int? {
        guard requestedOffset >= 0,
              rawItemCount > 0,
              requestedLimit > 0,
              reportedOffset == nil || reportedOffset == requestedOffset else { return nil }
        let base = requestedOffset
        let (candidate, overflow) = base.addingReportingOverflow(rawItemCount)
        guard !overflow, candidate > requestedOffset else { return nil }
        if let total {
            guard total >= 0 else { return nil }
            return candidate < total ? candidate : nil
        }
        return rawItemCount >= requestedLimit ? candidate : nil
    }

    static func searchPage<Value>(
        _ page: QobuzSearchResponse.Items<Value>?,
        requestedOffset: Int,
        requestedLimit: Int
    ) throws -> (offset: Int, nextOffset: Int?) {
        let offset = try validatedOffset(
            reportedOffset: page?.offset,
            requestedOffset: requestedOffset
        )
        guard let page else { return (offset, nil) }
        return (
            offset,
            nextOffset(
                reportedOffset: page.offset,
                requestedOffset: requestedOffset,
                rawItemCount: page.rawItemCount,
                total: page.total,
                requestedLimit: requestedLimit
            )
        )
    }
}
