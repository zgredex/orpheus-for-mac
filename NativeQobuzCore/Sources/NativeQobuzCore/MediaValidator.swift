import Foundation

public protocol MediaValidating: Sendable {
    func validate(_ fileURL: URL) async throws
}

public struct FFmpegMediaValidator: MediaValidating, Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public static func bundled() throws -> FFmpegMediaValidator {
        guard let executable = Bundle.module.url(
            forResource: "orpheus-media-validator",
            withExtension: nil,
            subdirectory: "MediaValidator/bin"
        ) else {
            throw NativeQobuzError.fileSystem("Mandatory bundled FFmpeg validator is missing")
        }
        return FFmpegMediaValidator(executableURL: executable)
    }

    public func validate(_ fileURL: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NativeQobuzError.fileSystem("Mandatory FFmpeg validator is missing or not executable")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [fileURL.path]
        let errors = Pipe()
        let state = ValidatorProcessState()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !state.isCancelled else {
                    continuation.resume(throwing: NativeQobuzError.cancelled)
                    return
                }
                process.terminationHandler = { process in
                    if state.isCancelled {
                        continuation.resume(throwing: NativeQobuzError.cancelled)
                        return
                    }
                    guard process.terminationStatus == 0 else {
                        let detail = String(
                            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(
                            throwing: NativeQobuzError.invalidResponse(
                                detail.isEmpty
                                    ? "Downloaded audio failed validation"
                                    : "Downloaded audio failed validation: \(detail)"
                            )
                        )
                        return
                    }
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: NativeQobuzError.fileSystem(error.localizedDescription))
                }
            }
        } onCancel: {
            state.cancel()
            if process.isRunning { process.terminate() }
        }
    }
}

private final class ValidatorProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
