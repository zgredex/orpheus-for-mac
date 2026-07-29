import Foundation
import OSLog

public enum QobuzLogLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ value: Self) -> Int {
        switch value {
        case .trace: 0
        case .debug: 1
        case .info: 2
        case .notice: 3
        case .warning: 4
        case .error: 5
        case .critical: 6
        }
    }
}

public struct QobuzLogEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let uptime: TimeInterval
    public let sessionID: UUID
    public let level: QobuzLogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]
    public let errorType: String?
    public let errorDescription: String?
    public let errorDomain: String?
    public let errorCode: Int?
    public let errorFailureReason: String?
    public let errorRecoverySuggestion: String?
    public let underlyingErrors: [String]?
    public let sourceFile: String
    public let sourceFunction: String
    public let sourceLine: UInt
    public let thread: String
    public let callStack: [String]?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        sessionID: UUID,
        level: QobuzLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:],
        errorType: String? = nil,
        errorDescription: String? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        errorFailureReason: String? = nil,
        errorRecoverySuggestion: String? = nil,
        underlyingErrors: [String]? = nil,
        sourceFile: String,
        sourceFunction: String,
        sourceLine: UInt,
        thread: String,
        callStack: [String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.uptime = uptime
        self.sessionID = sessionID
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.errorType = errorType
        self.errorDescription = errorDescription
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorFailureReason = errorFailureReason
        self.errorRecoverySuggestion = errorRecoverySuggestion
        self.underlyingErrors = underlyingErrors
        self.sourceFile = sourceFile
        self.sourceFunction = sourceFunction
        self.sourceLine = sourceLine
        self.thread = thread
        self.callStack = callStack
    }
}

/// Task-local diagnostic metadata. Download, browse, and Library operations use
/// this to carry correlation identifiers through nested async API calls.
public enum QobuzLogScope {
    @TaskLocal public static var metadata: [String: String] = [:]

    public static func withValue<T>(
        _ values: [String: String],
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $metadata.withValue(metadata.merging(values) { _, new in new }) {
            try await operation()
        }
    }
}

/// Process-wide structured diagnostics. Core code emits here; the macOS app
/// installs a durable JSONL sink while command-line tools still receive OSLog.
public final class QobuzDiagnostics: @unchecked Sendable {
    public typealias Sink = @Sendable (QobuzLogEntry) -> Void

    public static let shared = QobuzDiagnostics()
    public let sessionID = UUID()
    public let sessionStartedAt = Date()

    private let lock = NSLock()
    private var sink: Sink?
    private let subsystem = "com.orpheus.formac"

    private init() {}

    public func install(sink: Sink?) {
        lock.withLock { self.sink = sink }
    }

    public func log(
        _ level: QobuzLogLevel,
        category: String,
        _ message: String,
        metadata: [String: String] = [:],
        error: Error? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        let errorDetails = error.map { QobuzDiagnosticErrorDetails(error: $0) }
        let scoped = QobuzLogScope.metadata
            .merging(metadata) { _, new in new }
            .merging(errorDetails?.metadata ?? [:]) { _, diagnosticValue in diagnosticValue }
        let cleanedMetadata = Dictionary(uniqueKeysWithValues: scoped.map { key, value in
            (key, Self.redact(value, key: key))
        })
        let currentThreadName = Thread.current.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadName = Thread.isMainThread
            ? "main"
            : ((currentThreadName?.isEmpty == false) ? currentThreadName! : "background")
        let nativeError = error.map { $0 as NSError }
        let underlyingErrors = error.map(Self.underlyingErrorDescriptions)
        let entry = QobuzLogEntry(
            sessionID: sessionID,
            level: level,
            category: category,
            message: Self.redact(message),
            metadata: cleanedMetadata,
            errorType: error.map { String(reflecting: type(of: $0)) },
            errorDescription: errorDetails.map { Self.redact($0.description) },
            errorDomain: nativeError.map { Self.redact($0.domain) },
            errorCode: nativeError?.code,
            errorFailureReason: nativeError?.localizedFailureReason.map { Self.redact($0) },
            errorRecoverySuggestion: nativeError?.localizedRecoverySuggestion.map { Self.redact($0) },
            underlyingErrors: underlyingErrors?.isEmpty == false ? underlyingErrors : nil,
            sourceFile: file,
            sourceFunction: function,
            sourceLine: line,
            thread: threadName,
            callStack: level >= .error ? Thread.callStackSymbols : nil
        )
        emitToUnifiedLog(entry)
        lock.withLock { sink }?(entry)
    }

    public func trace(
        _ category: String, _ message: String, metadata: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.trace, category: category, message, metadata: metadata, file: file, function: function, line: line)
    }

    public func debug(
        _ category: String, _ message: String, metadata: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.debug, category: category, message, metadata: metadata, file: file, function: function, line: line)
    }

    public func info(
        _ category: String, _ message: String, metadata: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.info, category: category, message, metadata: metadata, file: file, function: function, line: line)
    }

    public func notice(
        _ category: String, _ message: String, metadata: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.notice, category: category, message, metadata: metadata, file: file, function: function, line: line)
    }

    public func warning(
        _ category: String, _ message: String, metadata: [String: String] = [:], error: Error? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.warning, category: category, message, metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public func error(
        _ category: String, _ message: String, metadata: [String: String] = [:], error: Error? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.error, category: category, message, metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public func critical(
        _ category: String, _ message: String, metadata: [String: String] = [:], error: Error? = nil,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        log(.critical, category: category, message, metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public static func redact(_ value: String, key: String? = nil) -> String {
        if let key, sensitiveKey(key) { return "<redacted>" }
        var result = value
        let replacements = [
            (
                #"(?i)([\"']?(?:user_auth_token|auth[_-]?token|app[_-]?secret|request_sig|authorization)[\"']?\s*:\s*)(\"[^\"]*\"|'[^']*')"#,
                #"$1\"<redacted>\""#
            ),
            (
                #"(?i)((?:user_auth_token|auth[_-]?token|app[_-]?secret|request_sig|authorization)(?:\s*=\s*|%3D))[^&\s,}\]]+"#,
                "$1<redacted>"
            ),
            (
                #"(?i)((?:X-User-Auth-Token|user_auth_token|auth[_-]?token|app[_-]?secret|request_sig|authorization)\s*:\s*)(?![\"'])[^\r\n,}\]]+"#,
                "$1<redacted>"
            ),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1<redacted>")
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    private static func sensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized.contains("secret")
            || normalized.contains("token")
            || normalized.contains("signature")
            || normalized == "request_sig"
            || normalized == "authorization"
            || normalized == "credentials"
    }

    private static func underlyingErrorDescriptions(_ root: Error) -> [String] {
        let rootError = root as NSError
        var pending: [NSError] = []
        if let underlying = rootError.userInfo[NSUnderlyingErrorKey] as? NSError {
            pending.append(underlying)
        }
        if let multiple = rootError.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
            pending.append(contentsOf: multiple)
        }
        var visited = Set<ObjectIdentifier>()
        var descriptions: [String] = []
        while let error = pending.first, descriptions.count < 16 {
            pending.removeFirst()
            guard visited.insert(ObjectIdentifier(error)).inserted else { continue }
            descriptions.append(redact(
                "\(String(reflecting: type(of: error))) domain=\(error.domain) code=\(error.code): \(error.localizedDescription)"
            ))
            if let child = error.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(child) }
            if let children = error.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
                pending.append(contentsOf: children)
            }
        }
        return descriptions
    }

    private func emitToUnifiedLog(_ entry: QobuzLogEntry) {
        let logger = Logger(subsystem: subsystem, category: entry.category)
        let details = entry.metadata.keys.sorted().compactMap { key in
            entry.metadata[key].map { "\(key)=\($0)" }
        }.joined(separator: " ")
        let metadataSuffix = details.isEmpty ? "" : " | \(details)"
        let errorSuffix = entry.errorDescription.map {
            " | error=\(entry.errorDomain ?? "unknown")[\(entry.errorCode ?? 0)] \($0)"
        } ?? ""
        let payload = "\(entry.message)\(metadataSuffix)\(errorSuffix) | source=\(entry.sourceFile):\(entry.sourceLine) \(entry.sourceFunction)"
        switch entry.level {
        case .trace, .debug:
            logger.debug("\(payload, privacy: .public)")
        case .info:
            logger.info("\(payload, privacy: .public)")
        case .notice:
            logger.notice("\(payload, privacy: .public)")
        case .warning:
            logger.warning("\(payload, privacy: .public)")
        case .error:
            logger.error("\(payload, privacy: .public)")
        case .critical:
            logger.critical("\(payload, privacy: .public)")
        }
    }
}

public let qobuzLog = QobuzDiagnostics.shared
