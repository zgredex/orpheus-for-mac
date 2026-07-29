import Foundation
import NativeQobuzCore
import XCTest
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

@MainActor
final class NativeLogSecurityTests: XCTestCase {
    func testCurrentLogSymlinkIsQuarantinedWithoutTouchingTarget() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.jsonl")
        let sentinel = Data("outside must remain unchanged".utf8)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: paths.logsDirectory.appendingPathComponent("orpheus-current.jsonl"),
            withDestinationURL: target
        )

        let store = NativeLogFileStore(paths: paths)
        try store.activate()
        store.append(logEntry(message: "secure log destination"))

        let current = paths.logsDirectory.appendingPathComponent("orpheus-current.jsonl")
        var persisted = false
        for _ in 0..<50 where !persisted {
            try await Task.sleep(for: .milliseconds(10))
            let data = (try? Data(contentsOf: current)) ?? Data()
            persisted = String(decoding: data, as: UTF8.self).contains("secure log destination")
        }

        XCTAssertTrue(persisted)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertFalse(try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false)
    }

    func testLogDirectorySymlinkIsRejectedWithoutWritingTarget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            defaultDownloadRoot: root.appendingPathComponent("Music")
        )
        let target = root.appendingPathComponent("outside-logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: paths.applicationSupportRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: paths.logsDirectory,
            withDestinationURL: target
        )

        let store = NativeLogFileStore(paths: paths)

        XCTAssertThrowsError(try store.activate())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeLogSecurity-\(UUID().uuidString)", isDirectory: true)
    }

    private func logEntry(message: String) -> QobuzLogEntry {
        QobuzLogEntry(
            sessionID: QobuzDiagnostics.shared.sessionID,
            level: .error,
            category: "test.security",
            message: message,
            sourceFile: #fileID,
            sourceFunction: #function,
            sourceLine: #line,
            thread: "test"
        )
    }
}
