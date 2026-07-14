import Foundation

/// Normalizes Swift errors before they enter any diagnostic sink. Foundation
/// reduces `DecodingError` to a generic Cocoa message, so preserve its semantic
/// kind, coding path, expected type, and explanation here once for JSONL,
/// Unified Logging, the in-app log reader, and propagated API errors.
struct QobuzDiagnosticErrorDetails: Sendable {
    let description: String
    let metadata: [String: String]

    init(error: Error) {
        guard let decodingError = error as? DecodingError else {
            description = error.localizedDescription
            metadata = [:]
            return
        }

        switch decodingError {
        case .typeMismatch(let expectedType, let context):
            let expectedTypeName = Self.typeName(expectedType)
            let path = Self.path(context.codingPath)
            description = "DecodingError.typeMismatch: expected \(expectedTypeName) at \(path). \(context.debugDescription)"
            metadata = Self.metadata(
                kind: "typeMismatch",
                path: path,
                context: context,
                additional: ["expectedType": expectedTypeName]
            )

        case .valueNotFound(let expectedType, let context):
            let expectedTypeName = Self.typeName(expectedType)
            let path = Self.path(context.codingPath)
            description = "DecodingError.valueNotFound: expected \(expectedTypeName) at \(path). \(context.debugDescription)"
            metadata = Self.metadata(
                kind: "valueNotFound",
                path: path,
                context: context,
                additional: ["expectedType": expectedTypeName]
            )

        case .keyNotFound(let key, let context):
            let path = Self.path(context.codingPath + [key])
            description = "DecodingError.keyNotFound: missing \(key.stringValue) at \(path). \(context.debugDescription)"
            metadata = Self.metadata(
                kind: "keyNotFound",
                path: path,
                context: context,
                additional: ["missingKey": key.stringValue]
            )

        case .dataCorrupted(let context):
            let path = Self.path(context.codingPath)
            description = "DecodingError.dataCorrupted at \(path). \(context.debugDescription)"
            metadata = Self.metadata(kind: "dataCorrupted", path: path, context: context)

        @unknown default:
            description = String(describing: decodingError)
            metadata = ["decodingKind": "unknown"]
        }
    }

    private static func metadata(
        kind: String,
        path: String,
        context: DecodingError.Context,
        additional: [String: String] = [:]
    ) -> [String: String] {
        [
            "codingPath": path,
            "decodingExplanation": context.debugDescription,
            "decodingKind": kind
        ].merging(additional) { _, new in new }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "<root>" }
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result
    }

    private static func typeName(_ type: Any.Type) -> String {
        String(reflecting: type).replacingOccurrences(of: "Swift.", with: "")
    }
}
