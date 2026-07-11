import Foundation

final class OrpheusRunner {
    enum Event: Equatable {
        case processStarted
        case outputLine(String)
        case fileProgress(ProgressEvent)
        case trackProgress(TrackProgressEvent)
        case albumProgress(AlbumProgressEvent)
    }

    struct ProgressEvent: Equatable {
        let percent: Double
        let downloaded: String
        let total: String
        let speed: String?
        let rawLine: String
    }

    struct TrackProgressEvent: Equatable {
        let completed: Int
        let total: Int?
        let current: Int?
        let state: TrackState
        let rawLine: String
    }

    struct AlbumProgressEvent: Equatable {
        let completed: Int
        let total: Int?
        let current: Int?
        let state: AlbumState
        let rawLine: String
    }

    enum TrackState: Equatable {
        case totalKnown
        case started
        case finished(TrackOutcome)
    }

    enum AlbumState: Equatable {
        case totalKnown
        case started
        case finished
    }

    enum TrackOutcome: String, Equatable {
        case downloaded
        case skipped
        case failed
    }

    struct CompletionError: LocalizedError {
        let status: Int32
        let output: String

        var errorDescription: String? {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Orpheus exited with code \(status)."
            }
            return OrpheusRunner.summarizeFailureOutput(trimmed)
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var capturedOutput = ""
    private var finished = false
    private var processLaunched = false

    private static let trackTotalRegex = try! NSRegularExpression(
        pattern: #"^Number of tracks:\s*([0-9]+)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let trackMarkerRegex = try! NSRegularExpression(
        pattern: #"^Track\s+([0-9]+)\s*/\s*([0-9]+)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let trackOutcomeRegex = try! NSRegularExpression(
        pattern: #"^===\s*Track\s+.+\s+(downloaded|skipped|failed)\s*===$"#,
        options: [.caseInsensitive]
    )
    private static let albumTotalRegex = try! NSRegularExpression(
        pattern: #"^Number of albums:\s*([0-9]+)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let albumMarkerRegex = try! NSRegularExpression(
        pattern: #"^Album\s+([0-9]+)\s*/\s*([0-9]+)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let albumOutcomeRegex = try! NSRegularExpression(
        pattern: #"^===\s*Album\s+.+\s+downloaded\s*===$"#,
        options: [.caseInsensitive]
    )
    private static let progressRegex = try! NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?)%.*?([0-9]+(?:\.[0-9]+)?\s*(?:[kKMGTPE]?i?B|[kKMGTPE]?B|[kKMGTPE]|B)?)/(\s*[0-9]+(?:\.[0-9]+)?\s*(?:[kKMGTPE]?i?B|[kKMGTPE]?B|[kKMGTPE]|B)?)"#
    )
    private static let speedRegex = try! NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?\s*(?:[kKMGTPE]?i?B|[kKMGTPE]?B|[kKMGTPE]|B)/s)"#
    )
    private static let csiRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"
    )
    private static let oscRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)"
    )

    func runDownload(
        url: String,
        helperURL: URL,
        projectURL: URL,
        downloadURL: URL,
        environment: [String: String] = [:]
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = helperURL
            process.arguments = [
                "--project", projectURL.path,
                "--output", downloadURL.path,
                "--",
                url
            ]
            process.currentDirectoryURL = projectURL

            process.environment = Self.sanitizedEnvironment(overrides: environment)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let parser = RunnerOutputParser()
            let outputQueue = DispatchQueue(label: "com.orpheusui.runner.output.\(UUID().uuidString)")

            lock.lock()
            self.process = process
            self.capturedOutput = ""
            self.finished = false
            self.processLaunched = false
            lock.unlock()

            let handleData: (Data) -> Void = { [weak self] data in
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                outputQueue.async {
                    self?.appendOutput(text)
                    for event in parser.events(from: text) {
                        continuation.yield(event)
                    }
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                handleData(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                handleData(handle.availableData)
            }

            process.terminationHandler = { [weak self] proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                outputQueue.async {
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    let output = self?.snapshotOutput() ?? ""
                    self?.markFinished()

                    if proc.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CompletionError(status: proc.terminationStatus, output: output))
                    }
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }

            lock.lock()
            guard !finished else {
                lock.unlock()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
                return
            }

            do {
                try process.run()
                processLaunched = true
                lock.unlock()
                continuation.yield(.processStarted)
            } catch {
                processLaunched = false
                self.process = nil
                finished = true
                lock.unlock()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: error)
            }
        }
    }

    static func parseTrackTotal(_ line: String) -> Int? {
        let clean = cleanLine(line)
        let ns = clean as NSString
        guard let match = trackTotalRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 2 else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    static func parseTrackMarker(_ line: String) -> (current: Int, total: Int)? {
        let clean = cleanLine(line)
        let ns = clean as NSString
        guard let match = trackMarkerRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 3,
              let current = Int(ns.substring(with: match.range(at: 1))),
              let total = Int(ns.substring(with: match.range(at: 2))) else {
            return nil
        }
        return (current, total)
    }

    static func parseTrackOutcome(_ line: String) -> TrackOutcome? {
        let clean = cleanLine(line)
        let ns = clean as NSString
        guard let match = trackOutcomeRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 2 else {
            return nil
        }
        return TrackOutcome(rawValue: ns.substring(with: match.range(at: 1)).lowercased())
    }

    static func parseAlbumTotal(_ line: String) -> Int? {
        let clean = cleanLine(line)
        let ns = clean as NSString
        guard let match = albumTotalRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 2 else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    static func parseAlbumMarker(_ line: String) -> (current: Int, total: Int)? {
        let clean = cleanLine(line)
        let ns = clean as NSString
        guard let match = albumMarkerRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 3,
              let current = Int(ns.substring(with: match.range(at: 1))),
              let total = Int(ns.substring(with: match.range(at: 2))) else {
            return nil
        }
        return (current, total)
    }

    static func parseAlbumOutcome(_ line: String) -> Bool {
        let clean = cleanLine(line)
        let ns = clean as NSString
        return albumOutcomeRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)) != nil
    }

    func cancel() {
        lock.lock()
        let process = process
        let alreadyFinished = finished
        let processWasLaunched = processLaunched
        if !alreadyFinished {
            finished = true
            self.process = nil
        }
        lock.unlock()

        guard !alreadyFinished, processWasLaunched, let process, process.isRunning else { return }
        process.terminate()
    }

    static func parseProgress(_ line: String) -> ProgressEvent? {
        let clean = cleanLine(line)
        guard !clean.isEmpty else { return nil }

        let ns = clean as NSString
        guard let match = progressRegex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 4 else {
            return nil
        }

        let totalRange = match.range(at: 3)
        let speedSearchStart = totalRange.location + totalRange.length
        let speedMatch = speedRegex.firstMatch(
            in: clean,
            range: NSRange(location: speedSearchStart, length: max(0, ns.length - speedSearchStart))
        )
        let speed = speedMatch.map { ns.substring(with: $0.range(at: 1)).normalizedProgressUnit }

        return ProgressEvent(
            percent: Double(ns.substring(with: match.range(at: 1))) ?? 0,
            downloaded: ns.substring(with: match.range(at: 2)).normalizedProgressUnit,
            total: ns.substring(with: match.range(at: 3)).normalizedProgressUnit,
            speed: speed,
            rawLine: clean
        )
    }

    static func parseEvents(from chunks: [String]) -> [Event] {
        let parser = RunnerOutputParser()
        var events: [Event] = []
        for chunk in chunks {
            events.append(contentsOf: parser.events(from: chunk))
        }
        events.append(contentsOf: parser.finish())
        return events
    }

    static func summarizeFailureOutput(_ output: String) -> String {
        let lines = splitProcessChunk(output)
            .map(cleanLine)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return output.trimmingCharacters(in: .whitespacesAndNewlines) }

        if lines.contains(where: { $0.localizedCaseInsensitiveContains("HTTP Error 404") })
            || lines.contains(where: { $0.localizedCaseInsensitiveContains("No result matching") }) {
            return "Qobuz could not find this item. It may be unavailable for your account region or no longer downloadable."
        }

        if let exception = lines.reversed().first(where: { line in
            line.contains(":")
                && !line.hasPrefix("File ")
                && !line.hasPrefix("Traceback ")
                && !line.hasPrefix("raise SystemExit")
        }) {
            if let separator = exception.firstIndex(of: ":") {
                let prefix = exception[..<separator]
                let messageStart = exception.index(after: separator)
                let message = exception[messageStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                if ["Exception", "RuntimeError", "ValueError", "KeyError"].contains(String(prefix)), !message.isEmpty {
                    return message
                }
            }
            return exception
        }

        return lines.suffix(6).joined(separator: "\n")
    }

    fileprivate static func splitProcessChunk(_ chunk: String) -> [String] {
        chunk
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    fileprivate static func cleanLine(_ line: String) -> String {
        stripANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSI(_ line: String) -> String {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let withoutOSC = oscRegex.stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
        let csiRange = NSRange(withoutOSC.startIndex..<withoutOSC.endIndex, in: withoutOSC)
        return csiRegex.stringByReplacingMatches(in: withoutOSC, range: csiRange, withTemplate: "")
    }

    static func sanitizedEnvironment(
        overrides: [String: String],
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let inheritedKeys = [
            "HOME",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "SYSTEM_VERSION_COMPAT",
            "__CF_USER_TEXT_ENCODING"
        ]
        var environment = Dictionary(uniqueKeysWithValues: inheritedKeys.compactMap { key in
            parent[key].map { (key, $0) }
        })
        environment["PATH"] = parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(overrides) { _, new in new }
        return environment
    }

    private func appendOutput(_ output: String) {
        lock.lock()
        capturedOutput += output
        if capturedOutput.count > 12_000 {
            capturedOutput = String(capturedOutput.suffix(12_000))
        }
        lock.unlock()
    }

    private func snapshotOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutput
    }

    private func markFinished() {
        lock.lock()
        finished = true
        process = nil
        processLaunched = false
        lock.unlock()
    }
}

private final class RunnerOutputParser {
    private var currentTrack: Int?
    private var totalTracks: Int?
    private var completedTracks = 0
    private var currentAlbum: Int?
    private var totalAlbums: Int?
    private var completedAlbums = 0
    private var pendingOutput = ""
    private var lastFileProgressLine: String?

    func events(from chunk: String) -> [OrpheusRunner.Event] {
        pendingOutput += chunk
        let split = splitCompleteLines(from: pendingOutput)
        pendingOutput = split.remainder

        var events = split.lines.flatMap(events(fromLine:))
        if let progress = liveProgressEvent(from: pendingOutput) {
            events.append(progress)
        }
        return events
    }

    func finish() -> [OrpheusRunner.Event] {
        let remainder = pendingOutput
        pendingOutput = ""
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return events(fromLine: remainder)
    }

    private func splitCompleteLines(from text: String) -> (lines: [String], remainder: String) {
        var lines: [String] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r" {
                let line = String(text[start..<index])
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }

        return (lines, String(text[start...]))
    }

    private func liveProgressEvent(from line: String) -> OrpheusRunner.Event? {
        let clean = OrpheusRunner.cleanLine(line)
        guard !clean.isEmpty,
              clean != lastFileProgressLine,
              let progress = OrpheusRunner.parseProgress(clean) else {
            return nil
        }
        lastFileProgressLine = clean
        return .fileProgress(progress)
    }

    private func events(fromLine line: String) -> [OrpheusRunner.Event] {
        var events: [OrpheusRunner.Event] = []

        let clean = OrpheusRunner.cleanLine(line)
        if !clean.isEmpty {
            events.append(.outputLine(clean))
        }

        if let total = OrpheusRunner.parseAlbumTotal(clean) {
            totalAlbums = max(totalAlbums ?? 0, total)
            events.append(.albumProgress(.init(
                completed: completedAlbums,
                total: totalAlbums,
                current: currentAlbum,
                state: .totalKnown,
                rawLine: clean
            )))
        }

        if let marker = OrpheusRunner.parseAlbumMarker(clean) {
            currentAlbum = marker.current
            totalAlbums = marker.total
            completedAlbums = max(completedAlbums, marker.current - 1)
            events.append(.albumProgress(.init(
                completed: completedAlbums,
                total: totalAlbums,
                current: currentAlbum,
                state: .started,
                rawLine: clean
            )))
        }

        if OrpheusRunner.parseAlbumOutcome(clean) {
            let completed = currentAlbum ?? (completedAlbums + 1)
            completedAlbums = max(completedAlbums, completed)
            events.append(.albumProgress(.init(
                completed: completedAlbums,
                total: totalAlbums,
                current: currentAlbum,
                state: .finished,
                rawLine: clean
            )))
        }

        if let total = OrpheusRunner.parseTrackTotal(clean) {
            totalTracks = max(totalTracks ?? 0, total)
            events.append(.trackProgress(.init(
                completed: completedTracks,
                total: totalTracks,
                current: currentTrack,
                state: .totalKnown,
                rawLine: clean
            )))
        }

        if let marker = OrpheusRunner.parseTrackMarker(clean) {
            currentTrack = marker.current
            totalTracks = marker.total
            completedTracks = max(completedTracks, marker.current - 1)
            events.append(.trackProgress(.init(
                completed: completedTracks,
                total: totalTracks,
                current: currentTrack,
                state: .started,
                rawLine: clean
            )))
        }

        if let outcome = OrpheusRunner.parseTrackOutcome(clean) {
            let completed = currentTrack ?? (completedTracks + 1)
            completedTracks = max(completedTracks, completed)
            events.append(.trackProgress(.init(
                completed: completedTracks,
                total: totalTracks,
                current: currentTrack,
                state: .finished(outcome),
                rawLine: clean
            )))
        }

        if clean != lastFileProgressLine, let progress = OrpheusRunner.parseProgress(clean) {
            lastFileProgressLine = clean
            events.append(.fileProgress(progress))
        }

        return events
    }
}

private extension String {
    var normalizedProgressUnit: String {
        replacingOccurrences(of: " ", with: "")
    }
}
