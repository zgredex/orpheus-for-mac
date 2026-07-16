import Foundation

extension LibraryFileTransferOperation {
    func resumablePartialSize() throws -> Int64 {
        guard let metadata = try fileSystem.metadata(at: partialPath) else { return 0 }
        switch metadata.kind {
        case .regularFile:
            return metadata.byteCount
        case .symbolicLink:
            throw NativeQobuzError.fileSystem("A symbolic link cannot be used as a partial download.")
        default:
            throw NativeQobuzError.fileSystem("The partial download is not a regular file.")
        }
    }

    func preparePartialFile(restart: Bool, totalBytes: Int64?) throws {
        let oldHandle = lock.withLock { () -> FileHandle? in
            let value = fileHandle
            fileHandle = nil
            return value
        }
        try oldHandle?.close()
        let handle = try fileSystem.writableHandle(at: partialPath, truncate: restart)
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
            continuation.yield(.progress(FileTransferProgress(
                bytesWritten: expectedOffset,
                totalBytes: totalBytes,
                bytesPerSecond: nil
            )))
        }
    }

    func restartFresh(replacing oldTask: URLSessionDataTask) {
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
        try? fileSystem.removeFile(partialPath, ifPresent: true)
        oldTask.cancel()
        let replacement = makeTask(session: session, offset: 0)
        let shouldStart = lock.withLock { () -> Bool in
            guard !finished, task == nil else { return false }
            task = replacement
            return true
        }
        if shouldStart { replacement.resume() } else { replacement.cancel() }
    }

    func completeTransfer(matching completedTask: URLSessionTask) {
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
            if context.totalBytesWritten > expected {
                try? fileSystem.removeFile(partialPath, ifPresent: true)
            }
            finishClaimed(
                .failure(.network("Audio transfer ended before the expected byte count.")),
                context: context
            )
            return
        }
        do {
            try fileSystem.replaceItem(at: destinationPath, with: partialPath)
            finishClaimed(.success(destination), context: context)
        } catch let error as NativeQobuzError {
            finishClaimed(.failure(error), context: context)
        } catch {
            finishClaimed(.failure(.fileSystem(error.localizedDescription)), context: context)
        }
    }
}
