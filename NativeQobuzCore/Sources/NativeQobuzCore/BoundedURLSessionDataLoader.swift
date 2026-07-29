import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BoundedURLSessionDataLoader: @unchecked Sendable {
    private let delegate: BoundedURLSessionDelegate
    private let session: URLSession

    init(session sourceSession: URLSession) {
        delegate = BoundedURLSessionDelegate()
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.orpheus.formac.network.bounded-data"
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(
            configuration: sourceSession.configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await delegate.data(for: request, session: session, maximumBytes: maximumBytes)
    }

    func data(
        from url: URL,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url), maximumBytes: maximumBytes)
    }
}

private final class BoundedURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<(Data, URLResponse), Error>

    private struct RequestState {
        let maximumBytes: Int
        let continuation: Continuation
        var data = Data()
        var response: URLResponse?
        var terminalError: Error?
    }

    private let lock = NSLock()
    private var requests: [Int: RequestState] = [:]

    func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw NativeQobuzError.invalidResponse("Invalid network response size limit")
        }
        let cancellation = BoundedRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock {
                    requests[task.taskIdentifier] = RequestState(
                        maximumBytes: maximumBytes,
                        continuation: continuation
                    )
                }
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let shouldCancel = lock.withLock {
            guard var state = requests[dataTask.taskIdentifier] else { return true }
            state.response = response
            if response.expectedContentLength > Int64(state.maximumBytes) {
                state.terminalError = sizeError(
                    maximumBytes: state.maximumBytes,
                    actualBytes: response.expectedContentLength
                )
            }
            requests[dataTask.taskIdentifier] = state
            return state.terminalError != nil
        }
        completionHandler(shouldCancel ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock {
            guard var state = requests[dataTask.taskIdentifier], state.terminalError == nil else {
                return true
            }
            guard data.count <= state.maximumBytes - state.data.count else {
                state.terminalError = sizeError(
                    maximumBytes: state.maximumBytes,
                    actualBytes: Int64(state.data.count) + Int64(data.count)
                )
                requests[dataTask.taskIdentifier] = state
                return true
            }
            state.data.append(data)
            requests[dataTask.taskIdentifier] = state
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let state = lock.withLock({ requests.removeValue(forKey: task.taskIdentifier) }) else {
            return
        }
        if let terminalError = state.terminalError {
            state.continuation.resume(throwing: terminalError)
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.data, response))
        } else {
            state.continuation.resume(
                throwing: NativeQobuzError.invalidResponse("Network request completed without a response")
            )
        }
    }

    private func sizeError(maximumBytes: Int, actualBytes: Int64) -> NativeQobuzError {
        .invalidResponse(
            "Network response exceeds the safe \(maximumBytes)-byte limit"
                + (actualBytes >= 0 ? " (reported \(actualBytes) bytes)" : "")
        )
    }
}

private final class BoundedRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func install(_ task: URLSessionTask) {
        let cancelNow = lock.withLock {
            self.task = task
            return isCancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}
