import Foundation

enum NativeProcessContext {
    static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var paths: NativePaths {
        guard isRunningUnitTests else { return NativePaths() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OrpheusNative-TestHost-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        return NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
            defaultDownloadRoot: root.appendingPathComponent("Music", isDirectory: true)
        )
    }
}
