import Foundation

enum AcceptanceStatus: String, Codable {
    case passed
    case failed
    case skipped
}

struct AcceptanceScenario: Codable {
    let id: String
    let title: String
    let required: Bool
    let status: AcceptanceStatus
    let durationMilliseconds: Int
    let detail: String?
}

struct AcceptanceSummary: Codable {
    let passed: Int
    let failed: Int
    let skipped: Int
    let releaseQualified: Bool
}

struct AcceptanceReport: Codable {
    let schemaVersion: Int
    let product: String
    let productVersion: String
    let operatingSystem: String
    let architecture: String
    let startedAt: Date
    var finishedAt: Date
    var accountRegion: String?
    var scenarios: [AcceptanceScenario]
    var summary: AcceptanceSummary
}

final class AcceptanceMatrix {
    private(set) var report: AcceptanceReport
    private let destination: URL
    private var redactor: DiagnosticRedactor

    init(destination: URL, secrets: [String]) throws {
        self.destination = destination
        redactor = DiagnosticRedactor(secrets: secrets)
        report = AcceptanceReport(
            schemaVersion: 1,
            product: "Orpheus for Mac",
            productVersion: "1.0.0",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: "arm64",
            startedAt: Date(),
            finishedAt: Date(),
            accountRegion: nil,
            scenarios: [],
            summary: AcceptanceSummary(passed: 0, failed: 0, skipped: 0, releaseQualified: false)
        )
        try persist()
    }

    func setAccountRegion(_ region: String) {
        report.accountRegion = region
        try? persist()
    }

    func addSecrets(_ secrets: [String]) {
        redactor.add(secrets)
    }

    func capture<T>(
        _ id: String,
        title: String,
        required: Bool = true,
        operation: () async throws -> T
    ) async -> T? {
        let start = ContinuousClock.now
        do {
            let value = try await operation()
            append(
                id: id,
                title: title,
                required: required,
                status: .passed,
                start: start,
                detail: nil
            )
            return value
        } catch {
            append(
                id: id,
                title: title,
                required: required,
                status: .failed,
                start: start,
                detail: redactor.clean(error.localizedDescription)
            )
            return nil
        }
    }

    func check(
        _ id: String,
        title: String,
        required: Bool = true,
        operation: () async throws -> Void
    ) async {
        _ = await capture(id, title: title, required: required, operation: operation) as Void?
    }

    func skip(_ id: String, title: String, required: Bool = true, reason: String) {
        report.scenarios.append(
            AcceptanceScenario(
                id: id,
                title: title,
                required: required,
                status: .skipped,
                durationMilliseconds: 0,
                detail: redactor.clean(reason)
            )
        )
        try? persist()
    }

    func finish() throws -> Bool {
        try persist()
        return report.summary.releaseQualified
    }

    private func append(
        id: String,
        title: String,
        required: Bool,
        status: AcceptanceStatus,
        start: ContinuousClock.Instant,
        detail: String?
    ) {
        let elapsed = start.duration(to: .now)
        let components = elapsed.components
        let milliseconds = max(
            0,
            Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
        )
        report.scenarios.append(
            AcceptanceScenario(
                id: id,
                title: title,
                required: required,
                status: status,
                durationMilliseconds: milliseconds,
                detail: detail
            )
        )
        try? persist()
    }

    private func persist() throws {
        report.finishedAt = Date()
        let passed = report.scenarios.count { $0.status == .passed }
        let failed = report.scenarios.count { $0.status == .failed }
        let skipped = report.scenarios.count { $0.status == .skipped }
        let requiredFailures = report.scenarios.contains {
            $0.required && $0.status != .passed
        }
        report.summary = AcceptanceSummary(
            passed: passed,
            failed: failed,
            skipped: skipped,
            releaseQualified: !report.scenarios.isEmpty && !requiredFailures
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination, options: .atomic)
    }
}

struct DiagnosticRedactor {
    private(set) var secrets: [String]

    init(secrets: [String]) {
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    mutating func add(_ values: [String]) {
        secrets.append(contentsOf: values.filter { !$0.isEmpty })
    }

    func clean(_ rawValue: String) -> String {
        var value = rawValue
        for secret in secrets {
            value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        value = value.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~",
            options: [.caseInsensitive]
        )
        value = replacing(#"https?://[^\s]+"#, in: value, with: "[REDACTED URL]")
        value = replacing(#"(?i)(token|secret|authorization)[=:][^\s,;]+"#, in: value, with: "$1=[REDACTED]")
        return String(value.prefix(2_000))
    }

    private func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}

struct AcceptanceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw AcceptanceFailure(message: message) }
}
