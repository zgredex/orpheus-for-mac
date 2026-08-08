import NativeQobuzCore

extension NativeDiagnosticSnapshot {
    func redacted() -> NativeDiagnosticSnapshot {
        NativeDiagnosticSnapshot(
            downloadQuality: QobuzDiagnostics.redact(downloadQuality),
            downloadRoot: QobuzDiagnostics.redact(downloadRoot),
            queue: queue.map { $0.redacted() },
            activities: activities.map { $0.redacted() },
            libraryTrackCount: libraryTrackCount,
            libraryIssueCount: libraryIssueCount,
            credentialsConfigured: credentialsConfigured
        )
    }
}

private extension NativeDiagnosticQueueSummary {
    func redacted() -> NativeDiagnosticQueueSummary {
        NativeDiagnosticQueueSummary(
            id: id,
            request: QobuzDiagnostics.redact(request),
            title: QobuzDiagnostics.redact(title),
            status: QobuzDiagnostics.redact(status),
            selectedTracks: selectedTracks,
            quality: quality.map { QobuzDiagnostics.redact($0) }
        )
    }
}

private extension NativeDiagnosticActivitySummary {
    func redacted() -> NativeDiagnosticActivitySummary {
        NativeDiagnosticActivitySummary(
            id: id,
            queueID: queueID,
            title: QobuzDiagnostics.redact(title),
            status: QobuzDiagnostics.redact(status),
            phase: QobuzDiagnostics.redact(phase),
            progress: progress,
            outputPath: outputPath.map { QobuzDiagnostics.redact($0) },
            warnings: warnings.map { QobuzDiagnostics.redact($0) },
            error: error.map { QobuzDiagnostics.redact($0) }
        )
    }
}
