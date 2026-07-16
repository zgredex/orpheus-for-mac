import Foundation
import NativeQobuzCore

struct NativePaths: Sendable {
    let applicationSupportRoot: URL
    let defaultDownloadRoot: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        applicationSupportRoot = support.appendingPathComponent("Orpheus for Mac", isDirectory: true)
        defaultDownloadRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Orpheus for Mac", isDirectory: true)
    }

    init(applicationSupportRoot: URL, defaultDownloadRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaultDownloadRoot = defaultDownloadRoot
    }

    var settingsURL: URL { applicationSupportRoot.appendingPathComponent("settings.json") }
    var archiveIndexURL: URL { applicationSupportRoot.appendingPathComponent("archive-index.json") }
    var credentialsURL: URL { applicationSupportRoot.appendingPathComponent("credentials.json") }
    var sessionURL: URL { applicationSupportRoot.appendingPathComponent("download-session.json") }
    var logsDirectory: URL { applicationSupportRoot.appendingPathComponent("Logs", isDirectory: true) }
}

protocol NativeSettingsStoring: Sendable {
    func load() throws -> NativeSettings
    func save(_ settings: NativeSettings) throws
}

struct NativeSettingsStore: NativeSettingsStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> NativeSettings {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            let value = NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes)
            try save(value)
            qobuzLog.notice(
                "persistence.settings",
                "Default settings created",
                metadata: ["settingsPath": paths.settingsURL.path]
            )
            return value
        }
        do {
            let value = try JSONDecoder().decode(NativeSettings.self, from: Data(contentsOf: paths.settingsURL))
            qobuzLog.debug(
                "persistence.settings",
                "Settings loaded",
                metadata: ["settingsPath": paths.settingsURL.path, "quality": value.quality.rawValue]
            )
            return value
        } catch {
            qobuzLog.error(
                "persistence.settings",
                "Settings could not be loaded",
                metadata: ["settingsPath": paths.settingsURL.path],
                error: error
            )
            throw error
        }
    }

    func save(_ settings: NativeSettings) throws {
        try fileManager.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: paths.settingsURL, options: .atomic)
        qobuzLog.info(
            "persistence.settings",
            "Settings saved",
            metadata: [
                "settingsPath": paths.settingsURL.path,
                "downloadPath": settings.downloadPath,
                "quality": settings.quality.rawValue
            ]
        )
    }
}

protocol NativeCredentialStoring: Sendable {
    func load() throws -> CredentialDraft?
    func save(_ credentials: CredentialDraft) throws
}

struct FileCredentialStore: NativeCredentialStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> CredentialDraft? {
        guard fileManager.fileExists(atPath: paths.credentialsURL.path) else {
            qobuzLog.info(
                "persistence.credentials",
                "No saved Qobuz credentials were found",
                metadata: ["credentialsConfigured": "false"]
            )
            return nil
        }
        do {
            let value = try JSONDecoder().decode(
                CredentialDraft.self,
                from: Data(contentsOf: paths.credentialsURL)
            )
            qobuzLog.info(
                "persistence.credentials",
                "Qobuz credentials loaded",
                metadata: ["credentialsConfigured": String(value.isComplete)]
            )
            return value
        } catch {
            qobuzLog.error(
                "persistence.credentials",
                "Qobuz credentials could not be loaded",
                metadata: ["credentialsConfigured": "unknown"],
                error: error
            )
            throw error
        }
    }

    func save(_ credentials: CredentialDraft) throws {
        try NativeSecureFileWriter.write(
            JSONEncoder.pretty.encode(credentials),
            to: paths.credentialsURL,
            fileManager: fileManager
        )
        qobuzLog.notice(
            "persistence.credentials",
            "Qobuz credentials saved with restricted file permissions",
            metadata: ["credentialsConfigured": String(credentials.isComplete)]
        )
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
