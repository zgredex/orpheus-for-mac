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
            try await validator.validate(invalid)
            XCTFail("Corrupt media must not pass validation")
        } catch let error as NativeQobuzError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        }
    }
}
