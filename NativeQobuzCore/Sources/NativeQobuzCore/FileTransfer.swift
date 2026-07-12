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
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in operation.cancel() }
            operation.start()
        }
    }
}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let continuation: AsyncThrowingStream<FileTransferEvent, Error>.Continuation
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0

    init(
        source: URL,
        destination: URL,
        configuration: URLSessionConfiguration,
        continuation: AsyncThrowingStream<FileTransferEvent, Error>.Continuation
    ) {
        self.source = source
        self.destination = destination
        self.configuration = configuration
        self.continuation = continuation
    }

    func start() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.downloadTask(with: source)
        self.session = session
        self.task = task
        lock.unlock()

        continuation.yield(.started)
        task.resume()
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let task = self.task
        let session = self.session
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        removePartialFile()
        continuation.finish(throwing: NativeQobuzError.cancelled)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard !isFinished else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleDate)
        let speed: Double?
        if elapsed >= 0.1 {
            speed = Double(totalBytesWritten - lastSampleBytes) / elapsed
            lastSampleDate = now
            lastSampleBytes = totalBytesWritten
        } else {
            speed = nil
        }
        continuation.yield(
            .progress(
                FileTransferProgress(
                    bytesWritten: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                    bytesPerSecond: speed
                )
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !isFinished else { return }
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw NativeQobuzError.http(response.statusCode, "Audio transfer failed.")
            }
            try installDownloadedFile(from: location)
            complete(.success(destination))
        } catch let error as NativeQobuzError {
            complete(.failure(error))
        } catch {
            complete(.failure(.fileSystem(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, !isFinished else { return }
        if (error as? URLError)?.code == .cancelled {
            complete(.failure(.cancelled))
        } else {
            complete(.failure(.network(error.localizedDescription)))
        }
    }

    private var isFinished: Bool {
        lock.withLock { finished }
    }

    private func installDownloadedFile(from temporaryURL: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let partialURL = self.partialURL
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: partialURL)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: destination)
        }
    }

    private func complete(_ result: Result<URL, NativeQobuzError>) {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil

        switch result {
        case .success(let url):
            continuation.yield(.completed(url))
            continuation.finish()
        case .failure(let error):
            removePartialFile()
            continuation.finish(throwing: error)
        }
    }

    private var partialURL: URL {
        destination.appendingPathExtension("partial")
    }

    private func removePartialFile() {
        try? fileManager.removeItem(at: partialURL)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
