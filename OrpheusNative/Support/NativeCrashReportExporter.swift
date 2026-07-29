import Foundation
import NativeQobuzCore

final class NativeCrashReportExporter: NativeCrashReportExporting, @unchecked Sendable {
    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private let sourceDirectories: [URL]
    private let bundleIdentifier: String
    private let processNames: [String]
    private let maximumReports: Int
    private let maximumAge: TimeInterval
    private let maximumReportBytes: Int64
    private let maximumScannedFiles: Int
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    init(
        sourceDirectories: [URL] = NativeCrashReportExporter.defaultSourceDirectories(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.orpheus.formac",
        processNames: [String] = ["OrpheusNative", "Orpheus for Mac"],
        maximumReports: Int = 10,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60,
        maximumReportBytes: Int64 = 20 * 1_024 * 1_024,
        maximumScannedFiles: Int = 2_000,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.sourceDirectories = sourceDirectories
        self.bundleIdentifier = bundleIdentifier
        self.processNames = processNames
        self.maximumReports = max(maximumReports, 1)
        self.maximumAge = maximumAge
        self.maximumReportBytes = max(
            1,
            min(maximumReportBytes, Int64(Int.max - 1))
        )
        self.maximumScannedFiles = max(maximumScannedFiles, 1)
        self.now = now
        self.fileManager = fileManager
    }

    func export(to destination: URL) throws -> NativeDiagnosticArtifactOutcome {
        let discovery = candidateReports()
        let candidates = discovery.candidates
        var messages = discovery.messages
        let selected = Array(candidates.prefix(maximumReports))
        if candidates.count > maximumReports {
            messages.append("Crash report export was limited to the newest \(maximumReports) matching reports.")
        }
        guard !selected.isEmpty else {
            return NativeDiagnosticArtifactOutcome(itemCount: 0, messages: messages)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var exported = 0
        for candidate in selected {
            do {
                let data = try NativeBoundedFileReader.readComplete(
                    candidate.url,
                    maximumBytes: Int(maximumReportBytes)
                )
                let redacted = QobuzDiagnostics.redact(String(decoding: data, as: UTF8.self))
                let target = uniqueDestination(
                    for: candidate.url.lastPathComponent,
                    in: destination,
                    sequence: exported
                )
                try Data(redacted.utf8).write(to: target, options: [.atomic])
                exported += 1
            } catch {
                let native = error as NSError
                messages.append(QobuzDiagnostics.redact(
                    "Could not export \(candidate.url.lastPathComponent): \(native.domain)[\(native.code)] \(native.localizedDescription)"
                ))
            }
        }
        return NativeDiagnosticArtifactOutcome(itemCount: exported, messages: messages)
    }

    private func candidateReports() -> (candidates: [Candidate], messages: [String]) {
        let cutoff = now().addingTimeInterval(-maximumAge)
        var candidates: [Candidate] = []
        var messages: [String] = []
        var seen = Set<String>()
        var scannedFiles = 0
        directoryLoop: for directory in sourceDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .fileSizeKey,
                    .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    messages.append(QobuzDiagnostics.redact(
                        "Could not inspect \(url.lastPathComponent): \(error.localizedDescription)"
                    ))
                    return true
                }
            ) else {
                messages.append("Could not enumerate crash reports in \(directory.path).")
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                guard ["ips", "crash"].contains(url.pathExtension.lowercased()) else { continue }
                scannedFiles += 1
                if scannedFiles > maximumScannedFiles {
                    messages.append("Crash report discovery stopped after \(maximumScannedFiles) candidate reports.")
                    break directoryLoop
                }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .creationDateKey,
                        .fileSizeKey,
                        .isSymbolicLinkKey
                    ])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let modifiedAt = values.contentModificationDate ?? values.creationDate ?? .distantPast
                    guard modifiedAt >= cutoff else { continue }
                    let size = Int64(values.fileSize ?? 0)
                    guard size <= maximumReportBytes else {
                        messages.append("Skipped oversized crash report \(url.lastPathComponent) (\(size) bytes).")
                        continue
                    }
                    guard seen.insert(url.standardizedFileURL.path).inserted,
                          try matchesApplication(url) else { continue }
                    candidates.append(Candidate(url: url, modifiedAt: modifiedAt))
                } catch {
                    messages.append(QobuzDiagnostics.redact(
                        "Could not inspect crash report \(url.lastPathComponent): \(error.localizedDescription)"
                    ))
                }
            }
        }
        let sorted = candidates.sorted { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt
                ? lhs.url.lastPathComponent < rhs.url.lastPathComponent
                : lhs.modifiedAt > rhs.modifiedAt
        }
        return (sorted, messages)
    }

    private func matchesApplication(_ url: URL) throws -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent.localizedLowercase
        if processNames.contains(where: { filename.contains($0.localizedLowercase) }) { return true }
        let prefix = try NativeBoundedFileReader.readPrefix(url, maximumBytes: 256 * 1_024)
        let text = String(decoding: prefix, as: UTF8.self).localizedLowercase
        return text.contains(bundleIdentifier.localizedLowercase)
            || processNames.contains(where: { text.contains($0.localizedLowercase) })
    }

    private func uniqueDestination(for filename: String, in directory: URL, sequence: Int) -> URL {
        let proposed = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let source = URL(fileURLWithPath: filename)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        return directory.appendingPathComponent("\(stem)-\(sequence + 1).\(ext)")
    }

    private static func defaultSourceDirectories() -> [URL] {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return []
        }
        return [
            library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
            library.appendingPathComponent("Logs/CrashReporter", isDirectory: true)
        ]
    }
}
