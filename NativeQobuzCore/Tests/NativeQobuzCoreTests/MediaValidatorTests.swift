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
        let fileSystem = try LibraryFileSystem(rootURL: root)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: validator.executableURL.path))
        do {
            _ = try await validator.validate(invalid, fileSystem: fileSystem)
            XCTFail("Corrupt media must not pass validation")
        } catch let error as NativeQobuzError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
            XCTAssertFalse(message.localizedCaseInsensitiveContains("bad file descriptor"))
        }
    }

    func testValidatorReceivesSecureFileDescriptorThroughStandardInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("descriptor-validator")
        let script = """
        #!/bin/sh
        if [ "$1" != "/dev/fd/0" ]; then
            echo "unexpected-input-path:$1" >&2
            exit 1
        fi
        payload=$(/bin/cat "$1") || {
            echo "descriptor-unreadable" >&2
            exit 1
        }
        if [ "$payload" != "descriptor payload" ]; then
            echo "unexpected-payload:$payload" >&2
            exit 1
        fi
        echo "descriptor-forwarded" >&2
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        let input = root.appendingPathComponent("input.flac")
        try Data("descriptor payload".utf8).write(to: input)
        let validator = FFmpegMediaValidator(executableURL: executable)
        let fileSystem = try LibraryFileSystem(rootURL: root)

        do {
            _ = try await validator.validate(input, fileSystem: fileSystem)
            XCTFail("The test validator deliberately exits with an error")
        } catch let error as NativeQobuzError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
            XCTAssertTrue(message.contains("descriptor-forwarded"), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("bad file descriptor"), message)
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
        let fileSystem = try LibraryFileSystem(rootURL: root)
        let started = Date()
        let task = Task { try await validator.validate(input, fileSystem: fileSystem) }

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
