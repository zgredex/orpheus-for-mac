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
            qobuzLog.critical("validation.setup", "Bundled media validator could not be located")
            throw NativeQobuzError.fileSystem("Mandatory bundled FFmpeg validator is missing")
        }
        qobuzLog.debug(
            "validation.setup",
            "Bundled media validator resolved",
            metadata: ["executablePath": executable.path]
        )
        return FFmpegMediaValidator(executableURL: executable)
    }

    public func validate(_ fileURL: URL) async throws {
        let validationID = UUID().uuidString
        let started = Date()
        let metadata = [
            "validationID": validationID,
            "filePath": fileURL.path,
            "validatorPath": executableURL.path
        ]
        qobuzLog.info("validation.media", "Media validation started", metadata: metadata)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            qobuzLog.critical(
                "validation.setup",
                "Media validator is missing or not executable",
                metadata: metadata
            )
            throw NativeQobuzError.fileSystem("Mandatory FFmpeg validator is missing or not executable")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [fileURL.path]
        let errors = Pipe()
        let state = ValidatorProcessState()
        let output = ValidatorOutput()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { process in
                        errors.fileHandleForReading.readabilityHandler = nil
                        output.append(errors.fileHandleForReading.readDataToEndOfFile())
                        if state.complete() {
                            continuation.resume(throwing: NativeQobuzError.cancelled)
                            return
                        }
                        guard process.terminationStatus == 0 else {
                            let detail = output.text
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
                        try state.run(process)
                        qobuzLog.debug(
                            "validation.process",
                            "Media validator process launched",
                            metadata: metadata.merging(["processID": String(process.processIdentifier)]) { _, new in new }
                        )
                    } catch let error as NativeQobuzError {
                        errors.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    } catch {
                        errors.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        continuation.resume(throwing: NativeQobuzError.fileSystem(error.localizedDescription))
                    }
                }
            } onCancel: {
                qobuzLog.notice("validation.media", "Media validation cancellation requested", metadata: metadata)
                state.cancel()
            }
            qobuzLog.notice(
                "validation.media",
                "Media validation passed",
                metadata: metadata.merging([
                    "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
                ]) { _, new in new }
            )
        } catch {
            if let native = error as? NativeQobuzError, case .cancelled = native {
                qobuzLog.notice("validation.media", "Media validation cancelled", metadata: metadata)
            } else {
                qobuzLog.error(
                    "validation.media",
                    "Media validation failed",
                    metadata: metadata.merging([
                        "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000)),
                        "validatorOutput": output.text
                    ]) { _, new in new },
                    error: error
                )
            }
            throw error
        }
    }
}

private final class ValidatorProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func run(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw NativeQobuzError.cancelled }
        self.process = process
        do {
            try process.run()
        } catch {
            self.process = nil
            throw error
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        return cancelled
    }
}

private final class ValidatorOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > 16_384 { data = Data(data.suffix(16_384)) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
