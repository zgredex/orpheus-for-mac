import Foundation
import NativeQobuzCore

struct NativePaths: Sendable {
    let applicationSupportRoot: URL
    let defaultDownloadRoot: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        applicationSupportRoot = support.appendingPathComponent("Orpheus for Mac", isDirectory: true)
        defaultDownloadRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Orpheus for Mac", isDirectory: true)
    }

    init(applicationSupportRoot: URL, defaultDownloadRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaultDownloadRoot = defaultDownloadRoot
    }

    func url(for artifact: NativePersistentArtifact) -> URL {
        applicationSupportRoot.appendingPathComponent(artifact.rawValue)
    }

    var configurationURL: URL { url(for: .configuration) }
    var archiveIndexURL: URL { url(for: .archiveIndex) }
    var sessionURL: URL { url(for: .session) }
    var logsDirectory: URL { applicationSupportRoot.appendingPathComponent("Logs", isDirectory: true) }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var persistence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
