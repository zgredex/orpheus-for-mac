import Foundation

final class LibraryFileTransferOperation: NSObject, @unchecked Sendable {
    let transferID = UUID().uuidString
    let startedAt = Date()
    let source: URL
    let destination: URL
    let fileSystem: LibraryFileSystem
    let configuration: URLSessionConfiguration
    let diagnosticMetadata: [String: String]
    let continuation: AsyncThrowingStream<FileTransferEvent, Error>.Continuation
    let lock = NSLock()

    var session: URLSession?
    var task: URLSessionDataTask?
    var fileHandle: FileHandle?
    var finished = false
    var requestedOffset: Int64 = 0
    var expectedTotalBytes: Int64?
    var totalBytesWritten: Int64 = 0
    var retriedFresh = false
    var lastSampleDate = Date()
    var lastSampleBytes: Int64 = 0
    var lastLoggedPercent = -10
    var lastLoggedBytes: Int64 = 0

    init(
        source: URL,
        destination: URL,
        fileSystem: LibraryFileSystem,
        configuration: URLSessionConfiguration,
        diagnosticMetadata: [String: String],
        continuation: AsyncThrowingStream<FileTransferEvent, Error>.Continuation
    ) {
        self.source = source
        self.destination = destination
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.diagnosticMetadata = diagnosticMetadata
        self.continuation = continuation
    }

    func start() {
        do {
            try fileSystem.createDirectory(destinationPath.parent)
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

    func makeTask(session: URLSession, offset: Int64) -> URLSessionDataTask {
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return session.dataTask(with: request)
    }

    func isCurrent(_ candidate: URLSessionTask) -> Bool {
        lock.withLock { !finished && task === candidate }
    }

    typealias FinishContext = (
        session: URLSession?,
        task: URLSessionTask?,
        handle: FileHandle?,
        totalBytesWritten: Int64,
        expectedTotalBytes: Int64?
    )

    func claimFinish(matching candidate: URLSessionTask? = nil) -> FinishContext? {
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

    func finish(
        _ result: Result<URL, NativeQobuzError>,
        matching candidate: URLSessionTask? = nil
    ) {
        guard let context = claimFinish(matching: candidate) else { return }
        finishClaimed(result, context: context)
    }

    func finishClaimed(_ result: Result<URL, NativeQobuzError>, context: FinishContext) {
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
            logFailure(error, bytesWritten: context.totalBytesWritten)
            context.session?.invalidateAndCancel()
            continuation.finish(throwing: error)
        }
    }

    private func logFailure(_ error: NativeQobuzError, bytesWritten: Int64) {
        let metadata = transferMetadata.merging([
            "bytesWritten": String(bytesWritten),
            "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
            "partialPath": partialURL.path
        ]) { _, new in new }
        if case .cancelled = error {
            qobuzLog.notice("transfer.lifecycle", "Audio transfer cancelled; partial file preserved when safe", metadata: metadata)
        } else {
            qobuzLog.error("transfer.lifecycle", "Audio transfer failed", metadata: metadata, error: error)
        }
    }

    var transferMetadata: [String: String] {
        diagnosticMetadata.merging([
            "transferID": transferID,
            "sourceHost": source.host ?? "unknown",
            "destinationPath": destination.path
        ]) { _, new in new }
    }

    var destinationPath: LibraryRelativePath {
        get throws { try fileSystem.relativePath(for: destination) }
    }

    var partialPath: LibraryRelativePath {
        get throws { try destinationPath.parent.appending(destinationPath.lastComponent! + ".partial") }
    }

    var partialURL: URL {
        guard let path = try? partialPath else { return destination.appendingPathExtension("partial") }
        return fileSystem.displayURL(for: path)
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
