import Foundation
import XCTest
@testable import NativeQobuzCore

final class DiagnosticsTests: XCTestCase {
    func testStructuredEntryCapturesScopeErrorAndSourceLocation() async {
        let capture = DiagnosticCapture()
        QobuzDiagnostics.shared.install { capture.append($0) }
        defer { QobuzDiagnostics.shared.install(sink: nil) }

        await QobuzLogScope.withValue(["queueID": "queue-17", "operation": "download"]) {
            qobuzLog.error(
                "test.diagnostics",
                "A precise failure occurred",
                metadata: ["trackID": "track-9"],
                error: TestFailure.example
            )
        }

        let entry = capture.entries.last
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.category, "test.diagnostics")
        XCTAssertEqual(entry?.metadata["queueID"], "queue-17")
        XCTAssertEqual(entry?.metadata["operation"], "download")
        XCTAssertEqual(entry?.metadata["trackID"], "track-9")
        XCTAssertTrue(entry?.errorType?.contains("TestFailure") == true)
        XCTAssertEqual(entry?.errorDescription, "Diagnostic test failure")
        XCTAssertFalse(entry?.errorDomain?.isEmpty == true)
        XCTAssertNotNil(entry?.errorCode)
        XCTAssertTrue(entry?.sourceFile.hasSuffix("DiagnosticsTests.swift") == true)
        XCTAssertTrue(entry?.sourceFunction.contains("testStructuredEntry") == true)
        XCTAssertGreaterThan(entry?.sourceLine ?? 0, 0)
        XCTAssertFalse(entry?.thread.isEmpty == true)
        XCTAssertFalse(entry?.callStack?.isEmpty == true)
    }

    func testRedactionRemovesCredentialValuesFromMessagesAndMetadata() {
        let capture = DiagnosticCapture()
        QobuzDiagnostics.shared.install { capture.append($0) }
        defer { QobuzDiagnostics.shared.install(sink: nil) }

        qobuzLog.warning(
            "test.security",
            "authorization=BearerSecret user_auth_token=TokenSecret request_sig=SignatureSecret",
            metadata: [
                "appSecret": "AppSecretValue",
                "auth-token": "TokenValue",
                "safeID": "12345"
            ]
        )

        let entry = capture.entries.last
        let serialized = ([entry?.message, entry?.metadata.description].compactMap { $0 }).joined()
        XCTAssertFalse(serialized.contains("BearerSecret"))
        XCTAssertFalse(serialized.contains("TokenSecret"))
        XCTAssertFalse(serialized.contains("SignatureSecret"))
        XCTAssertFalse(serialized.contains("AppSecretValue"))
        XCTAssertFalse(serialized.contains("TokenValue"))
        XCTAssertEqual(entry?.metadata["safeID"], "12345")
        XCTAssertEqual(entry?.metadata["appSecret"], "<redacted>")

        let json = #"{"auth_token":"JSONSecret","safe":"visible"}"#
        let redactedJSON = QobuzDiagnostics.redact(json)
        let decoded = try? JSONSerialization.jsonObject(with: Data(redactedJSON.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["auth_token"], "<redacted>")
        XCTAssertEqual(decoded?["safe"], "visible")
        XCTAssertFalse(redactedJSON.contains("JSONSecret"))
    }

    func testUnderlyingErrorChainIsPreservedAndRedacted() {
        let capture = DiagnosticCapture()
        QobuzDiagnostics.shared.install { capture.append($0) }
        defer { QobuzDiagnostics.shared.install(sink: nil) }
        let underlying = NSError(
            domain: "NSPOSIXErrorDomain",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied auth_token=SecretValue"]
        )
        let root = NSError(
            domain: "Orpheus.Download",
            code: 71,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not install the downloaded file",
                NSUnderlyingErrorKey: underlying
            ]
        )

        qobuzLog.error("test.diagnostics", "Nested failure", error: root)

        let entry = capture.entries.last
        XCTAssertEqual(entry?.errorDomain, "Orpheus.Download")
        XCTAssertEqual(entry?.errorCode, 71)
        XCTAssertTrue(entry?.underlyingErrors?.joined().contains("NSPOSIXErrorDomain") == true)
        XCTAssertFalse(entry?.underlyingErrors?.joined().contains("SecretValue") == true)
    }

    func testDecodingErrorPreservesPreciseKindPathTypeAndExplanation() throws {
        let capture = DiagnosticCapture()
        QobuzDiagnostics.shared.install { capture.append($0) }
        defer { QobuzDiagnostics.shared.install(sink: nil) }

        let payload = #"{"awards":[{"awarded_at":1530230400}]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(StrictAlbum.self, from: Data(payload.utf8))
        ) { error in
            qobuzLog.error("api.decode", "Could not decode test response", error: error)
        }

        let entry = capture.entries.last
        XCTAssertEqual(entry?.metadata["decodingKind"], "typeMismatch")
        XCTAssertEqual(entry?.metadata["codingPath"], "awards[0].awarded_at")
        XCTAssertEqual(entry?.metadata["expectedType"], "String")
        XCTAssertEqual(
            entry?.metadata["decodingExplanation"],
            "Expected to decode String but found number instead."
        )
        XCTAssertEqual(
            entry?.errorDescription,
            "DecodingError.typeMismatch: expected String at awards[0].awarded_at. "
                + "Expected to decode String but found number instead."
        )
    }
}

private struct StrictAlbum: Decodable {
    let awards: [StrictAward]
}

private struct StrictAward: Decodable {
    let awardedAt: String

    private enum CodingKeys: String, CodingKey {
        case awardedAt = "awarded_at"
    }
}

private enum TestFailure: LocalizedError {
    case example

    var errorDescription: String? { "Diagnostic test failure" }
}

private final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [QobuzLogEntry] = []

    func append(_ entry: QobuzLogEntry) {
        lock.lock()
        values.append(entry)
        lock.unlock()
    }

    var entries: [QobuzLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
