import Foundation
import NativeQobuzCore

extension NativeDownloadOperation {
    func validateStoredLibraryPaths() throws {
        guard let downloadRootPath else {
            guard activityID == nil,
                  outputURLs.isEmpty,
                  assetURLs.isEmpty,
                  checkpoint?.outputURL == nil,
                  resumablePartial == nil else {
                throw NativeQobuzError.invalidResponse(
                    "An Activity download operation has no authoritative Library root."
                )
            }
            return
        }

        let root = URL(fileURLWithPath: downloadRootPath, isDirectory: true).standardizedFileURL
        guard downloadRootPath.hasPrefix("/"), root.path == downloadRootPath else {
            throw NativeQobuzError.invalidResponse(
                "A download operation contains an invalid Library root."
            )
        }
        let storedURLs = outputURLs
            + assetURLs
            + [checkpoint?.outputURL, resumablePartial?.url].compactMap { $0 }
        guard storedURLs.allSatisfy({ url in
            url.isFileURL
                && url.path == url.standardizedFileURL.path
                && QobuzPathSafety.isContained(url, in: root, allowingRoot: false)
        }) else {
            throw NativeQobuzError.invalidResponse(
                "A download operation contains an invalid Library item path."
            )
        }
        guard Set(outputURLs.map(\.path)).count == outputURLs.count,
              Set(assetURLs.map(\.path)).count == assetURLs.count else {
            throw NativeQobuzError.invalidResponse(
                "A download operation contains duplicate Library item paths."
            )
        }
        _ = try NativeDownloadRecoveryArtifactResolver().artifacts(for: self)
        if checkpoint?.phase == .indexingLibrary || checkpoint?.phase == .complete {
            guard activityID != nil, !outputURLs.isEmpty else {
                throw NativeQobuzError.invalidResponse(
                    "A Library-index recovery receipt has no Activity owner or downloaded output."
                )
            }
        }
    }
}

/// Validated, in-memory projection of the durable indexing receipt held by a
/// `NativeDownloadOperation`. It deliberately persists no parallel state.
struct NativePendingLibraryIndex: Equatable, Sendable {
    let activityID: UUID
    let root: URL
    let changedAudioPaths: [LibraryRelativePath]

    var changedAudioURLs: [URL] {
        changedAudioPaths.map { path in
            path.isRoot ? root : root.appendingPathComponent(path.rawValue)
        }
    }
}

struct NativeLibraryIndexReceiptValidator: Sendable {
    func validate(_ operation: NativeDownloadOperation) async throws -> NativePendingLibraryIndex {
        let task = Task.detached(priority: .utility) {
            try Self.validateSynchronously(operation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func validateSynchronously(
        _ operation: NativeDownloadOperation
    ) throws -> NativePendingLibraryIndex {
        guard operation.hasLibraryIndexReceipt,
              let activityID = operation.activityID,
              let root = operation.downloadRootURL,
              !operation.outputURLs.isEmpty else {
            throw NativeQobuzError.invalidResponse(
                "The saved download has no complete Library-index recovery receipt."
            )
        }

        let fileSystem = try LibraryFileSystem(rootURL: root, createIfMissing: false)
        var paths: [LibraryRelativePath] = []
        var seen = Set<LibraryRelativePath>()
        for url in operation.outputURLs {
            try Task.checkCancellation()
            guard url.isFileURL else {
                throw NativeQobuzError.invalidResponse(
                    "A saved download output is not a local file."
                )
            }
            let path = try fileSystem.relativePath(for: url)
            guard seen.insert(path).inserted else { continue }
            guard let metadata = try fileSystem.metadata(at: path) else {
                throw LibraryFileSystemError.missing(path.rawValue)
            }
            guard metadata.kind == .regularFile else {
                throw metadata.kind == .symbolicLink
                    ? LibraryFileSystemError.symbolicLink(path.rawValue)
                    : LibraryFileSystemError.notRegularFile(path.rawValue)
            }
            paths.append(path)
        }
        return NativePendingLibraryIndex(
            activityID: activityID,
            root: fileSystem.rootURL,
            changedAudioPaths: paths
        )
    }
}

enum NativeLibraryIndexRecoveryOutcome {
    case completed
    case interrupted
    case failed
}

/// Service-independent completion barrier for both fresh downloads and
/// restored operations. This component cannot resolve Qobuz or transfer audio.
@MainActor
final class NativeLibraryIndexRecoveryRunner {
    private let ledger: NativeDownloadLedger
    private let validator: NativeLibraryIndexReceiptValidator

    init(
        ledger: NativeDownloadLedger,
        validator: NativeLibraryIndexReceiptValidator = NativeLibraryIndexReceiptValidator()
    ) {
        self.ledger = ledger
        self.validator = validator
    }

    func run(
        queueID: UUID,
        resumed: Bool,
        indexLibrary: @escaping @MainActor (URL, [URL]) async throws -> Void,
        isTerminating: @escaping @MainActor () -> Bool,
        checkpoint: @escaping @MainActor () -> Void
    ) async -> NativeLibraryIndexRecoveryOutcome {
        let startedAt = Date()
        do {
            guard let operation = ledger.operation(for: queueID) else {
                throw NativeQobuzError.invalidResponse("The saved download operation is missing.")
            }
            let receipt = try await validator.validate(operation)
            try Task.checkCancellation()
            ledger.transition(queueID: queueID, activityID: receipt.activityID, to: .indexingLibrary)
            ledger.updateActivity(receipt.activityID) {
                $0.phase = resumed ? "Resuming Library indexing" : "Indexing Library"
                $0.errorMessage = nil
                $0.bytesPerSecond = nil
            }
            checkpoint()
            try await indexLibrary(receipt.root, receipt.changedAudioURLs)
            try Task.checkCancellation()
            ledger.markLibraryIndexed(queueID: queueID, activityID: receipt.activityID)
            checkpoint()
            qobuzLog.notice(
                "download.library.recovery",
                resumed ? "Interrupted Library indexing resumed locally" : "Library indexing completed",
                metadata: [
                    "queueID": queueID.uuidString,
                    "activityID": receipt.activityID.uuidString,
                    "downloadRoot": receipt.root.path,
                    "changedAudioCount": String(receipt.changedAudioPaths.count),
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ]
            )
            return .completed
        } catch let error where error.isQobuzCancellation {
            finishInterruption(queueID: queueID, isTerminating: isTerminating())
            checkpoint()
            return .interrupted
        } catch {
            finishFailure(queueID: queueID, error: error)
            checkpoint()
            return .failed
        }
    }

    private func finishInterruption(queueID: UUID, isTerminating: Bool) {
        let activityID = ledger.operation(for: queueID)?.activityID
        ledger.transition(
            queueID: queueID,
            activityID: activityID,
            to: isTerminating ? .paused : .cancelled
        )
        if let activityID {
            ledger.updateActivity(activityID) {
                $0.phase = isTerminating ? "Paused after app closed" : "Library indexing cancelled"
                $0.bytesPerSecond = nil
            }
        }
        qobuzLog.notice(
            "download.library.recovery",
            isTerminating ? "Library indexing paused for app termination" : "Library indexing cancelled",
            metadata: ["queueID": queueID.uuidString]
        )
    }

    private func finishFailure(queueID: UUID, error: Error) {
        let message = "Library indexing failed: \(error.localizedDescription)"
        let activityID = ledger.operation(for: queueID)?.activityID
        ledger.transition(queueID: queueID, activityID: activityID, to: .failed(message))
        if let activityID {
            ledger.updateActivity(activityID) {
                $0.phase = message
                $0.errorMessage = message
                $0.bytesPerSecond = nil
            }
        }
        qobuzLog.error(
            "download.library.recovery",
            "Library indexing receipt could not be completed; Qobuz redownload was not attempted",
            metadata: ["queueID": queueID.uuidString],
            error: error
        )
    }
}
