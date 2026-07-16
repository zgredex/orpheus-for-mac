import Foundation

final class QobuzHTTPTransport: @unchecked Sendable {
    private let baseURL: URL
    private let authToken: String
    private let session: URLSession
    private let retryPolicy: QobuzRetryPolicy
    private let retryScheduler: QobuzRetryScheduler

    init(
        baseURL: URL,
        authToken: String,
        session: URLSession,
        retryPolicy: QobuzRetryPolicy,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date,
        jitter: @escaping @Sendable () -> Double
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.session = session
        self.retryPolicy = retryPolicy
        retryScheduler = QobuzRetryScheduler(
            policy: retryPolicy,
            sleep: sleep,
            now: now,
            jitter: jitter
        )
    }

    func get<T: Decodable>(
        endpoint: String,
        parameters: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        let requestID = UUID().uuidString
        let requestStarted = Date()
        let baseMetadata = [
            "requestID": requestID,
            "endpoint": endpoint,
            "responseType": String(reflecting: T.self),
            "parameterNames": parameters.keys.sorted().joined(separator: ",")
        ]
        let request = try makeRequest(endpoint: endpoint, parameters: parameters, metadata: baseMetadata)
        qobuzLog.info(
            "api.request",
            "Qobuz request started",
            metadata: baseMetadata.merging([
                "method": "GET",
                "host": request.url?.host ?? "unknown",
                "maxAttempts": String(retryPolicy.maxAttempts)
            ]) { _, new in new }
        )

        for attempt in 0..<retryPolicy.maxAttempts {
            let attemptStarted = Date()
            let attemptMetadata = baseMetadata.merging([
                "attempt": String(attempt + 1),
                "maxAttempts": String(retryPolicy.maxAttempts)
            ]) { _, new in new }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    qobuzLog.error("api.response", "Qobuz returned a non-HTTP response", metadata: attemptMetadata)
                    throw NativeQobuzError.invalidResponse("Expected an HTTP response.")
                }
                let responseMetadata = attemptMetadata.merging([
                    "status": String(http.statusCode),
                    "responseBytes": String(data.count),
                    "durationMs": String(Int(Date().timeIntervalSince(attemptStarted) * 1_000))
                ]) { _, new in new }
                qobuzLog.debug("api.response", "Qobuz response received", metadata: responseMetadata)
                if (200...202).contains(http.statusCode) {
                    return try decode(
                        T.self,
                        data: data,
                        response: http,
                        requestStarted: requestStarted,
                        metadata: responseMetadata
                    )
                }
                if isRetryable(status: http.statusCode), attempt + 1 < retryPolicy.maxAttempts {
                    qobuzLog.warning(
                        "api.retry",
                        "Qobuz request will retry after HTTP failure",
                        metadata: responseMetadata
                    )
                    try await wait(attempt: attempt, response: http, metadata: responseMetadata)
                    continue
                }
                let mapped = mapHTTPError(status: http.statusCode, data: data, response: http)
                qobuzLog.error(
                    "api.request",
                    "Qobuz request failed with HTTP error",
                    metadata: responseMetadata,
                    error: mapped
                )
                throw LoggedQobuzRequestError(error: mapped)
            } catch let logged as LoggedQobuzRequestError {
                throw logged.error
            } catch let error where error.isQobuzCancellation {
                qobuzLog.notice("api.request", "Qobuz request cancelled", metadata: attemptMetadata)
                throw NativeQobuzError.cancelled
            } catch let error as NativeQobuzError {
                qobuzLog.error("api.request", "Qobuz request stopped", metadata: attemptMetadata, error: error)
                throw error
            } catch {
                let networkFailure = NativeQobuzError.networkFailure(error)
                if networkFailure.isConnectivityLoss {
                    qobuzLog.warning(
                        "api.connectivity",
                        "Qobuz request stopped because the network path is unavailable",
                        metadata: attemptMetadata,
                        error: networkFailure
                    )
                    throw networkFailure
                }
                if isRetryable(error: error), attempt + 1 < retryPolicy.maxAttempts {
                    qobuzLog.warning(
                        "api.retry",
                        "Qobuz request will retry after network failure",
                        metadata: attemptMetadata,
                        error: error
                    )
                    try await wait(attempt: attempt, response: nil, metadata: attemptMetadata)
                    continue
                }
                qobuzLog.error(
                    "api.request",
                    "Qobuz request failed with a network error",
                    metadata: attemptMetadata,
                    error: error
                )
                throw networkFailure
            }
        }
        qobuzLog.error(
            "api.request",
            "Qobuz request exhausted all retry attempts",
            metadata: baseMetadata.merging([
                "totalDurationMs": String(Int(Date().timeIntervalSince(requestStarted) * 1_000))
            ]) { _, new in new }
        )
        throw NativeQobuzError.network("Request failed after retrying.")
    }

    private func makeRequest(
        endpoint: String,
        parameters: [String: String],
        metadata: [String: String]
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        ) else {
            qobuzLog.error("api.request", "Could not construct Qobuz endpoint", metadata: metadata)
            throw NativeQobuzError.invalidResponse("Could not construct endpoint \(endpoint).")
        }
        components.queryItems = parameters
            .filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name
            }
        guard let url = components.url else {
            qobuzLog.error("api.request", "Could not construct Qobuz request URL", metadata: metadata)
            throw NativeQobuzError.invalidResponse("Could not construct a Qobuz request URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        return request
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: HTTPURLResponse,
        requestStarted: Date,
        metadata: [String: String]
    ) throws -> (T, HTTPURLResponse) {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            qobuzLog.info(
                "api.request",
                "Qobuz request completed",
                metadata: metadata.merging([
                    "totalDurationMs": String(Int(Date().timeIntervalSince(requestStarted) * 1_000))
                ]) { _, new in new }
            )
            return (decoded, response)
        } catch {
            let details = QobuzDiagnosticErrorDetails(error: error)
            qobuzLog.error("api.decode", "Could not decode Qobuz response", metadata: metadata, error: error)
            throw LoggedQobuzRequestError(error: .invalidResponse(details.description))
        }
    }

    private var headers: [String: String] {
        var values = [
            "X-Device-Platform": "android",
            "X-Device-Model": "Pixel 3",
            "X-Device-Os-Version": "10",
            "X-Device-Manufacturer-Id": "482D8CB7-015D-402F-A93B-5EEF0E0996F3",
            "X-App-Version": "5.16.1.5",
            "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 10; Pixel 3 Build/QP1A.190711.020))QobuzMobileAndroid/5.16.1.5-b21041415"
        ]
        if !authToken.isEmpty { values["X-User-Auth-Token"] = authToken }
        return values
    }

    private func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    private func isRetryable(error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed
        ].contains(code)
    }

    private func wait(
        attempt: Int,
        response: HTTPURLResponse?,
        metadata: [String: String]
    ) async throws {
        let delay = retryScheduler.delay(attempt: attempt, response: response)
        qobuzLog.info(
            "api.retry.wait",
            "Waiting before the next Qobuz request attempt",
            metadata: metadata.merging([
                "delay": String(describing: delay.duration),
                "delaySource": delay.source.rawValue
            ]) { _, new in new }
        )
        try await retryScheduler.wait(delay)
    }

    private func mapHTTPError(status: Int, data: Data, response: HTTPURLResponse) -> NativeQobuzError {
        let rawBody = String(data: data, encoding: .utf8) ?? ""
        let body = rawBody.count > 500 ? String(rawBody.prefix(500)) + "… [truncated]" : rawBody
        if status == 401 || status == 403 { return .invalidCredentials }
        if status == 404 {
            let region = response.value(forHTTPHeaderField: "X-Store")
                .map { String($0.prefix(2)).uppercased() }
            let suffix = region.map { " It may belong to the \($0) store." } ?? ""
            return .unavailable("This Qobuz item is unavailable for the account region.\(suffix)")
        }
        return .http(status, body.isEmpty ? "No response body" : body)
    }

}

private struct LoggedQobuzRequestError: Error {
    let error: NativeQobuzError
}
