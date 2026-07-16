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
    func events(
        from source: URL,
        to destination: URL,
        fileSystem: LibraryFileSystem
    ) -> AsyncThrowingStream<FileTransferEvent, Error>
}

public struct URLSessionFileTransferClient: FileTransferClient, Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func events(
        from source: URL,
        to destination: URL,
        fileSystem: LibraryFileSystem
    ) -> AsyncThrowingStream<FileTransferEvent, Error> {
        AsyncThrowingStream { continuation in
            let operation = LibraryFileTransferOperation(
                source: source,
                destination: destination,
                fileSystem: fileSystem,
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
    return .restart(totalBytes: positiveContentLength(response))
}

private struct HTTPContentRange {
    let start: Int64
    let total: Int64?

    init?(_ value: String?) {
        guard let value else { return nil }
        let pattern = #"^bytes\s+(\d+)-(\d+)/(\d+|\*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let startRange = Range(match.range(at: 1), in: value),
              let endRange = Range(match.range(at: 2), in: value),
              let start = Int64(value[startRange]),
              let end = Int64(value[endRange]),
              start <= end else { return nil }
        let total = Range(match.range(at: 3), in: value).flatMap { range -> Int64? in
            let raw = value[range]
            return raw == "*" ? nil : Int64(raw)
        }
        if let total, end >= total { return nil }
        self.start = start
        self.total = total
    }
}

private func positiveContentLength(_ response: HTTPURLResponse) -> Int64? {
    if let value = response.value(forHTTPHeaderField: "Content-Length"),
       let length = Int64(value), length > 0 { return length }
    return response.expectedContentLength > 0 ? response.expectedContentLength : nil
}
