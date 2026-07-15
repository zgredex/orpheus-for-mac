import Darwin
import Foundation
import XCTest
@testable import NativeQobuzCore

final class MediaValidatorTests: XCTestCase {
    func testBundledValidatorRejectsInvalidAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("invalid.flac")
        try Data("not audio".utf8).write(to: invalid)
        let validator = try FFmpegMediaValidator.bundled()

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: validator.executableURL.path))
        do {
            _ = try await validator.validate(invalid)
            XCTFail("Corrupt media must not pass validation")
        } catch let error as NativeQobuzError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        }
    }

    func testCancellationTerminatesRunningValidatorPromptly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("slow-validator")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        let input = root.appendingPathComponent("input.flac")
        try Data("input".utf8).write(to: input)
        let validator = FFmpegMediaValidator(executableURL: executable)
        let started = Date()
        let task = Task { try await validator.validate(input) }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled validation must not complete successfully")
        } catch let error as NativeQobuzError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

}
