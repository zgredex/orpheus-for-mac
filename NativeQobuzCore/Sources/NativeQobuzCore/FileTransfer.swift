import Foundation

public struct FileTransferProgress: Equatable, Sendable {
    public let bytesWritten: Int64
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?

    public init(bytesWritten: Int64, totalBytes: Int64?, bytesPerSecond: Double?) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesWritten) / Double(totalBytes), 0), 1)
    }
}

public enum FileTransferEvent: Equatable, Sendable {
    case started
    case progress(FileTransferProgress)
    case completed(URL)
}

public protocol FileTransferClient: Sendable {
    func events(from source: URL, to destination: URL) -> AsyncThrowingStream<FileTransferEvent, Error>
}

public struct URLSessionFileTransferClient: FileTransferClient, Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func events(from source: URL, to destination: URL) -> AsyncThrowingStream<FileTransferEvent, Error> {
        AsyncThrowingStream { continuation in
            let operation = DownloadOperation(
                source: source,
                destination: destination,
                configuration: configuration,
                diagnosticMetadata: QobuzLogScope.metadata,
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in operation.cancel() }
            operation.start()
        }
    }
}

enum FileTransferResponseDisposition: Equatable {
    case append(totalBytes: Int64?)
    case restart(totalBytes: Int64?)
    case retryFresh
}

func fileTransferDisposition(
    for response: HTTPURLResponse,
    requestedOffset: Int64,
    alreadyRetriedFresh: Bool
) throws -> FileTransferResponseDisposition {
    let status = response.statusCode
    if status == 416 {
        if requestedOffset > 0, !alreadyRetriedFresh { return .retryFresh }
        throw NativeQobuzError.http(status, "Audio range is not satisfiable.")
    }
    guard (200...299).contains(status) else {
        throw NativeQobuzError.http(status, "Audio transfer failed.")
    }

    if status == 206 {
        guard let range = HTTPContentRange(response.value(forHTTPHeaderField: "Content-Range")),
              range.start == requestedOffset else {
            if requestedOffset > 0, !alreadyRetriedFresh { return .retryFresh }
            throw NativeQobuzError.invalidResponse("Qobuz returned an unsafe audio byte range.")
        }
        return .append(totalBytes: range.total)
    }

    let total = positiveContentLength(response)
    return .restart(totalBytes: total)
}

private struct HTTPContentRange {
    let start: Int64
    let end: Int64
    let total: Int64?

    init?(_ value: String?) {
        guard let value else { return nil }
        let pattern = #"^bytes\s+(\d+)-(\d+)/(\d+|\*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              match.range.location != NSNotFound,
              let startRange = Range(match.range(at: 1), in: value),
              let endRange = Range(match.range(at: 2), in: value),
              let start = Int64(value[startRange]),
              let end = Int64(value[endRange]),
              start <= end else { return nil }
        let totalRange = Range(match.range(at: 3), in: value)
        let total = totalRange.flatMap { range -> Int64? in
            let raw = value[range]
            return raw == "*" ? nil : Int64(raw)
        }
        if let total, end >= total { return nil }
        self.start = start
        self.end = end
        self.total = total
    }
}

private func positiveContentLength(_ response: HTTPURLResponse) -> Int64? {
    if let value = response.value(forHTTPHeaderField: "Content-Length"),
       let length = Int64(value), length > 0 {
        return length
    }
    return response.expectedContentLength > 0 ? response.expectedContentLength : nil
}

private final class DownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transferID = UUID().uuidString
    private let startedAt = Date()
    private let source: URL
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let diagnosticMetadata: [String: String]
    private let continuation: AsyncThrowingStream<FileTransferEvent, Error>.Continuation
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var finished = false
    private var requestedOffset: Int64 = 0
    private var expectedTotalBytes: Int64?
    private var totalBytesWritten: Int64 = 0
    private var retriedFresh = false
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0
    private var lastLoggedPercent = -10
    private var lastLoggedBytes: Int64 = 0

    init(
        source: URL,
        destination: URL,
        configuration: URLSessionConfiguration,
        diagnosticMetadata: [String: String],
        continuation: AsyncThrowingStream<FileTransferEvent, Error>.Continuation
    ) {
        self.source = source
        self.destination = destination
        self.configuration = configuration
        self.diagnosticMetadata = diagnosticMetadata
        self.continuation = continuation
    }

    func start() {
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let offset = try resumablePartialSize()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = makeTask(session: session, offset: offset)
            lock.withLock {
                guard !finished else { return }
                self.session = session
                self.task = task
                requestedOffset = offset
                totalBytesWritten = offset
                lastSampleBytes = offset
                lastLoggedBytes = offset
            }
            qobuzLog.info(
                "transfer.lifecycle",
                offset > 0 ? "Audio transfer resuming from partial file" : "Audio transfer started",
                metadata: transferMetadata.merging([
                    "resumeOffset": String(offset),
                    "resumed": String(offset > 0)
                ]) { _, new in new }
            )
            continuation.yield(.started)
            task.resume()
        } catch let error as NativeQobuzError {
            qobuzLog.error("transfer.lifecycle", "Audio transfer could not start", metadata: transferMetadata, error: error)
            finish(.failure(error))
        } catch {
            qobuzLog.error("transfer.lifecycle", "Audio transfer could not start", metadata: transferMetadata, error: error)
            finish(.failure(.fileSystem(error.localizedDescription)))
        }
    }

    func cancel() {
        finish(.failure(.cancelled))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard isCurrent(dataTask), let response = response as? HTTPURLResponse else {
            qobuzLog.warning("transfer.response", "Rejected an unexpected transfer response", metadata: transferMetadata)
            completionHandler(.cancel)
            return
        }
        let offset = lock.withLock { requestedOffset }
        let retried = lock.withLock { retriedFresh }
        let responseMetadata = transferMetadata.merging([
            "status": String(response.statusCode),
            "requestedOffset": String(offset),
            "contentLength": response.value(forHTTPHeaderField: "Content-Length") ?? "unknown",
            "contentRange": response.value(forHTTPHeaderField: "Content-Range") ?? "none"
        ]) { _, new in new }
        qobuzLog.debug("transfer.response", "Audio transfer response received", metadata: responseMetadata)
        do {
            switch try fileTransferDisposition(
                for: response,
                requestedOffset: offset,
                alreadyRetriedFresh: retried
            ) {
            case .append(let total):
                qobuzLog.info(
                    "transfer.response",
                    "Server accepted resumed audio transfer",
                    metadata: responseMetadata.merging(["expectedBytes": total.map(String.init) ?? "unknown"]) { _, new in new }
                )
                try preparePartialFile(restart: false, totalBytes: total)
                completionHandler(.allow)
            case .restart(let total):
                qobuzLog.info(
                    "transfer.response",
                    "Server requested a fresh audio transfer",
                    metadata: responseMetadata.merging(["expectedBytes": total.map(String.init) ?? "unknown"]) { _, new in new }
                )
                try preparePartialFile(restart: true, totalBytes: total)
                completionHandler(.allow)
            case .retryFresh:
                qobuzLog.warning(
                    "transfer.resume",
                    "Resume response was unsafe; retrying once from byte zero",
                    metadata: responseMetadata
                )
                completionHandler(.cancel)
                restartFresh(replacing: dataTask)
            }
        } catch let error as NativeQobuzError {
            qobuzLog.error("transfer.response", "Audio transfer response was rejected", metadata: responseMetadata, error: error)
            completionHandler(.cancel)
            finish(.failure(error), matching: dataTask)
        } catch {
            qobuzLog.error("transfer.response", "Audio transfer response handling failed", metadata: responseMetadata, error: error)
            completionHandler(.cancel)
            finish(.failure(.fileSystem(error.localizedDescription)), matching: dataTask)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isCurrent(dataTask) else { return }
        let now = Date()
        do {
            let sample: (written: Int64, total: Int64?, speed: Double?, shouldLog: Bool, percent: Int?) = try lock.withLock {
                guard !finished, self.task === dataTask, let fileHandle else {
                    throw NativeQobuzError.cancelled
                }
                try fileHandle.write(contentsOf: data)
                totalBytesWritten += Int64(data.count)
                let elapsed = now.timeIntervalSince(lastSampleDate)
                let speed: Double?
                if elapsed >= 0.1 {
                    speed = Double(totalBytesWritten - lastSampleBytes) / elapsed
                    lastSampleDate = now
                    lastSampleBytes = totalBytesWritten
                } else {
                    speed = nil
                }
                let percent = expectedTotalBytes.flatMap { total in
                    total > 0 ? Int((Double(totalBytesWritten) / Double(total) * 100).rounded(.down)) : nil
                }
                let crossedPercentBucket = percent.map { ($0 / 10) * 10 >= lastLoggedPercent + 10 } ?? false
                let crossedByteBucket = totalBytesWritten - lastLoggedBytes >= 16 * 1_024 * 1_024
                let shouldLog = crossedPercentBucket || crossedByteBucket
                if shouldLog {
                    if let percent { lastLoggedPercent = (percent / 10) * 10 }
                    lastLoggedBytes = totalBytesWritten
                }
                return (totalBytesWritten, expectedTotalBytes, speed, shouldLog, percent)
            }
            continuation.yield(
                .progress(
                    FileTransferProgress(
                        bytesWritten: sample.written,
                        totalBytes: sample.total,
                        bytesPerSecond: sample.speed
                    )
                )
            )
            if sample.shouldLog {
                var progressMetadata = transferMetadata
                progressMetadata["bytesWritten"] = String(sample.written)
                progressMetadata["totalBytes"] = sample.total.map(String.init) ?? "unknown"
                progressMetadata["percent"] = sample.percent.map(String.init) ?? "unknown"
                progressMetadata["bytesPerSecond"] = sample.speed.map { String(Int($0)) } ?? "unknown"
                qobuzLog.debug(
                    "transfer.progress",
                    "Audio transfer progress",
                    metadata: progressMetadata
                )
            }
        } catch let error as NativeQobuzError {
            qobuzLog.error("transfer.write", "Writing audio transfer data failed", metadata: transferMetadata, error: error)
            finish(.failure(error), matching: dataTask)
        } catch {
            qobuzLog.error("transfer.write", "Writing audio transfer data failed", metadata: transferMetadata, error: error)
            finish(.failure(.fileSystem(error.localizedDescription)), matching: dataTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard isCurrent(task) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(.cancelled), matching: task)
            } else {
                qobuzLog.error("transfer.network", "Audio transfer task failed", metadata: transferMetadata, error: error)
                finish(.failure(NativeQobuzError.networkFailure(error)), matching: task)
            }
        } else {
            completeTransfer(matching: task)
        }
    }

    private func makeTask(session: URLSession, offset: Int64) -> URLSessionDataTask {
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return session.dataTask(with: request)
    }

    private func resumablePartialSize() throws -> Int64 {
        do {
            return try NoFollowFile.size(at: partialURL)
        } catch NoFollowFileError.missing {
            return 0
        } catch NoFollowFileError.symbolicLink {
            qobuzLog.warning(
                "transfer.resume",
                "Unsafe symbolic-link partial file was removed",
                metadata: transferMetadata
            )
            try fileManager.removeItem(at: partialURL)
            return 0
        } catch NoFollowFileError.notRegular {
            throw NativeQobuzError.fileSystem("The partial download is not a regular file.")
        } catch NoFollowFileError.system(let code) {
            throw NativeQobuzError.fileSystem("Could not inspect the partial download (errno \(code)).")
        }
    }

    private func preparePartialFile(restart: Bool, totalBytes: Int64?) throws {
        let oldHandle = lock.withLock { () -> FileHandle? in
            let value = fileHandle
            fileHandle = nil
            return value
        }
        try oldHandle?.close()
        if restart {
            try? fileManager.removeItem(at: partialURL)
        }
        let handle: FileHandle
        do {
            handle = try NoFollowFile.writableHandle(at: partialURL, truncate: restart)
        } catch NoFollowFileError.symbolicLink {
            throw NativeQobuzError.fileSystem("A symbolic link cannot be used as a partial download.")
        } catch NoFollowFileError.notRegular {
            throw NativeQobuzError.fileSystem("The partial download is not a regular file.")
        } catch NoFollowFileError.missing {
            throw NativeQobuzError.fileSystem("Could not create the partial download.")
        } catch NoFollowFileError.system(let code) {
            throw NativeQobuzError.fileSystem("Could not open the partial download (errno \(code)).")
        }
        let actualOffset = try handle.seekToEnd()
        let expectedOffset = restart ? 0 : lock.withLock { requestedOffset }
        guard actualOffset == UInt64(expectedOffset) else {
            qobuzLog.error(
                "transfer.resume",
                "Partial file size changed while preparing resume",
                metadata: transferMetadata.merging([
                    "expectedOffset": String(expectedOffset),
                    "actualOffset": String(actualOffset)
                ]) { _, new in new }
            )
            try handle.close()
            throw NativeQobuzError.invalidResponse("The partial audio file changed while resuming.")
        }
        let accepted = lock.withLock { () -> Bool in
            guard !finished else { return false }
            fileHandle = handle
            expectedTotalBytes = totalBytes
            totalBytesWritten = expectedOffset
            lastSampleBytes = expectedOffset
            lastSampleDate = Date()
            return true
        }
        guard accepted else {
            try handle.close()
            throw NativeQobuzError.cancelled
        }
        if expectedOffset > 0 {
            qobuzLog.notice(
                "transfer.resume",
                "Partial audio file accepted for resume",
                metadata: transferMetadata.merging([
                    "resumeOffset": String(expectedOffset),
                    "expectedBytes": totalBytes.map(String.init) ?? "unknown"
                ]) { _, new in new }
            )
            continuation.yield(
                .progress(
                    FileTransferProgress(
                        bytesWritten: expectedOffset,
                        totalBytes: totalBytes,
                        bytesPerSecond: nil
                    )
                )
            )
        }
    }

    private func restartFresh(replacing oldTask: URLSessionDataTask) {
        let context: (URLSession, FileHandle?)? = lock.withLock {
            guard !finished, task === oldTask, let session else { return nil }
            let handle = fileHandle
            fileHandle = nil
            task = nil
            retriedFresh = true
            requestedOffset = 0
            expectedTotalBytes = nil
            totalBytesWritten = 0
            lastSampleBytes = 0
            return (session, handle)
        }
        guard let (session, handle) = context else { return }
        qobuzLog.notice("transfer.resume", "Restarting audio transfer from byte zero", metadata: transferMetadata)
        try? handle?.close()
        try? fileManager.removeItem(at: partialURL)
        oldTask.cancel()
        let replacement = makeTask(session: session, offset: 0)
        let shouldStart = lock.withLock { () -> Bool in
            guard !finished, task == nil else { return false }
            task = replacement
            return true
        }
        if shouldStart { replacement.resume() }
        else { replacement.cancel() }
    }

    private func completeTransfer(matching completedTask: URLSessionTask) {
        guard var context = claimFinish(matching: completedTask) else { return }
        try? context.handle?.close()
        context.handle = nil
        if let expected = context.expectedTotalBytes, context.totalBytesWritten != expected {
            qobuzLog.error(
                "transfer.integrity",
                "Audio transfer byte count did not match the server response",
                metadata: transferMetadata.merging([
                    "expectedBytes": String(expected),
                    "actualBytes": String(context.totalBytesWritten)
                ]) { _, new in new }
            )
            if context.totalBytesWritten > expected { try? fileManager.removeItem(at: partialURL) }
            finishClaimed(
                .failure(.network("Audio transfer ended before the expected byte count.")),
                context: context
            )
            return
        }
        do {
            try installDownloadedFile()
            finishClaimed(.success(destination), context: context)
        } catch let error as NativeQobuzError {
            finishClaimed(.failure(error), context: context)
        } catch {
            finishClaimed(.failure(.fileSystem(error.localizedDescription)), context: context)
        }
    }

    private func installDownloadedFile() throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: destination)
        }
    }

    private func isCurrent(_ candidate: URLSessionTask) -> Bool {
        lock.withLock { !finished && task === candidate }
    }

    private typealias FinishContext = (
        session: URLSession?,
        task: URLSessionTask?,
        handle: FileHandle?,
        totalBytesWritten: Int64,
        expectedTotalBytes: Int64?
    )

    private func claimFinish(matching candidate: URLSessionTask? = nil) -> FinishContext? {
        lock.withLock {
            guard !finished else { return nil }
            if let candidate, task !== candidate { return nil }
            finished = true
            let values = (session, task, fileHandle, totalBytesWritten, expectedTotalBytes)
            session = nil
            task = nil
            fileHandle = nil
            return values
        }
    }

    private func finish(
        _ result: Result<URL, NativeQobuzError>,
        matching candidate: URLSessionTask? = nil
    ) {
        guard let context = claimFinish(matching: candidate) else { return }
        finishClaimed(result, context: context)
    }

    private func finishClaimed(
        _ result: Result<URL, NativeQobuzError>,
        context: FinishContext
    ) {
        try? context.handle?.close()
        context.task?.cancel()

        switch result {
        case .success(let url):
            qobuzLog.notice(
                "transfer.lifecycle",
                "Audio transfer completed",
                metadata: transferMetadata.merging([
                    "bytesWritten": String(context.totalBytesWritten),
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                    "installedPath": url.path
                ]) { _, new in new }
            )
            context.session?.finishTasksAndInvalidate()
            continuation.yield(.completed(url))
            continuation.finish()
        case .failure(let error):
            if case .cancelled = error {
                qobuzLog.notice(
                    "transfer.lifecycle",
                    "Audio transfer cancelled; partial file preserved when safe",
                    metadata: transferMetadata.merging([
                        "bytesWritten": String(context.totalBytesWritten),
                        "partialPath": partialURL.path
                    ]) { _, new in new }
                )
            } else {
                qobuzLog.error(
                    "transfer.lifecycle",
                    "Audio transfer failed",
                    metadata: transferMetadata.merging([
                        "bytesWritten": String(context.totalBytesWritten),
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                        "partialPath": partialURL.path
                    ]) { _, new in new },
                    error: error
                )
            }
            context.session?.invalidateAndCancel()
            continuation.finish(throwing: error)
        }
    }

    private var transferMetadata: [String: String] {
        diagnosticMetadata.merging([
            "transferID": transferID,
            "sourceHost": source.host ?? "unknown",
            "destinationPath": destination.path
        ]) { _, new in new }
    }

    private var partialURL: URL {
        destination.appendingPathExtension("partial")
    }

}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
