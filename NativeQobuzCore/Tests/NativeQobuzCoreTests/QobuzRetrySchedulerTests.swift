import Foundation
import XCTest
@testable import NativeQobuzCore

final class QobuzRetrySchedulerTests: XCTestCase {
    func testNonFiniteRetryInputsFallBackWithoutTrapping() {
        let scheduler = QobuzRetryScheduler(
            policy: QobuzRetryPolicy(
                maxAttempts: 2,
                baseDelay: .seconds(1),
                jitterFraction: 0.1
            ),
            sleep: { _ in },
            now: { Date() },
            jitter: { .nan }
        )
        let response = HTTPURLResponse(
            url: URL(string: "https://www.qobuz.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "NaN"]
        )

        let delay = scheduler.delay(attempt: 0, response: response)

        XCTAssertEqual(delay.source, .exponentialBackoff)
        XCTAssertEqual(delay.duration, .seconds(1))
    }
}
