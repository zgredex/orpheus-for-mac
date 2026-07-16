import Foundation

extension LibraryFileTransferOperation: URLSessionDataDelegate {
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
                    metadata: responseMetadata.merging([
                        "expectedBytes": total.map(String.init) ?? "unknown"
                    ]) { _, new in new }
                )
                try preparePartialFile(restart: false, totalBytes: total)
                completionHandler(.allow)
            case .restart(let total):
                qobuzLog.info(
                    "transfer.response",
                    "Server requested a fresh audio transfer",
                    metadata: responseMetadata.merging([
                        "expectedBytes": total.map(String.init) ?? "unknown"
                    ]) { _, new in new }
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
            let sample = try append(data, from: dataTask, now: now)
            continuation.yield(.progress(FileTransferProgress(
                bytesWritten: sample.written,
                totalBytes: sample.total,
                bytesPerSecond: sample.speed
            )))
            if sample.shouldLog { logProgress(sample) }
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

    private typealias ProgressSample = (
        written: Int64,
        total: Int64?,
        speed: Double?,
        shouldLog: Bool,
        percent: Int?
    )

    private func append(_ data: Data, from dataTask: URLSessionDataTask, now: Date) throws -> ProgressSample {
        try lock.withLock {
            guard !finished, task === dataTask, let fileHandle else { throw NativeQobuzError.cancelled }
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
            let crossedPercent = percent.map { ($0 / 10) * 10 >= lastLoggedPercent + 10 } ?? false
            let crossedBytes = totalBytesWritten - lastLoggedBytes >= 16 * 1_024 * 1_024
            let shouldLog = crossedPercent || crossedBytes
            if shouldLog {
                if let percent { lastLoggedPercent = (percent / 10) * 10 }
                lastLoggedBytes = totalBytesWritten
            }
            return (totalBytesWritten, expectedTotalBytes, speed, shouldLog, percent)
        }
    }

    private func logProgress(_ sample: ProgressSample) {
        var metadata = transferMetadata
        metadata["bytesWritten"] = String(sample.written)
        metadata["totalBytes"] = sample.total.map(String.init) ?? "unknown"
        metadata["percent"] = sample.percent.map(String.init) ?? "unknown"
        metadata["bytesPerSecond"] = sample.speed.map { String(Int($0)) } ?? "unknown"
        qobuzLog.debug("transfer.progress", "Audio transfer progress", metadata: metadata)
    }
}
