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

    func url(for artifact: NativePersistentArtifact) -> URL {
        applicationSupportRoot.appendingPathComponent(artifact.rawValue)
    }

    var settingsURL: URL { url(for: .settings) }
    var archiveIndexURL: URL { url(for: .archiveIndex) }
    var credentialsURL: URL { url(for: .credentials) }
    var sessionURL: URL { url(for: .session) }
    var logsDirectory: URL { applicationSupportRoot.appendingPathComponent("Logs", isDirectory: true) }
}

protocol NativeSettingsStoring: Sendable {
    func load() throws -> NativeSettings
    func save(_ settings: NativeSettings) throws
}

struct NativeSettingsStore: NativeSettingsStoring, Sendable {
    let paths: NativePaths
    private let files: NativeApplicationSupportFileStore

    init(paths: NativePaths) {
        self.paths = paths
        files = NativeApplicationSupportFileStore(rootURL: paths.applicationSupportRoot)
    }

    func load() throws -> NativeSettings {
        do {
            guard let data = try files.read(.settings) else {
                return try createDefaultSettings(reason: "No settings file exists")
            }
            let value = try JSONDecoder().decode(NativeSettings.self, from: data)
            qobuzLog.debug(
                "persistence.settings",
                "Settings loaded",
                metadata: ["settingsPath": paths.settingsURL.path, "quality": value.quality.rawValue]
            )
            return value
        } catch {
            qobuzLog.error(
                "persistence.settings",
                "Settings could not be loaded and will be reset",
                metadata: ["settingsPath": paths.settingsURL.path],
                error: error
            )
            do {
                let rejectedURL = try files.quarantine(
                    .settings,
                    rejectedPrefix: "settings.rejected"
                )
                qobuzLog.notice(
                    "persistence.settings",
                    "Unreadable settings were quarantined",
                    metadata: ["rejectedPath": rejectedURL.path]
                )
                return try createDefaultSettings(reason: "Unreadable settings were quarantined")
            } catch let quarantineError {
                qobuzLog.error(
                    "persistence.settings",
                    "Unreadable settings could not be quarantined",
                    error: quarantineError
                )
                throw error
            }
        }
    }

    private func createDefaultSettings(reason: String) throws -> NativeSettings {
        let value = NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes)
        try save(value)
        qobuzLog.notice(
            "persistence.settings",
            "Default settings created",
            metadata: ["settingsPath": paths.settingsURL.path, "reason": reason]
        )
        return value
    }

    func save(_ settings: NativeSettings) throws {
        let data = try JSONEncoder.pretty.encode(settings)
        try files.write(data, to: .settings)
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

struct FileCredentialStore: NativeCredentialStoring, Sendable {
    let paths: NativePaths
    private let files: NativeApplicationSupportFileStore

    init(paths: NativePaths) {
        self.paths = paths
        files = NativeApplicationSupportFileStore(rootURL: paths.applicationSupportRoot)
    }

    func load() throws -> CredentialDraft? {
        do {
            guard let data = try files.read(.credentials) else {
                qobuzLog.info(
                    "persistence.credentials",
                    "No saved Qobuz credentials were found",
                    metadata: ["credentialsConfigured": "false"]
                )
                return nil
            }
            let value = try JSONDecoder().decode(
                CredentialDraft.self,
                from: data
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
                "Qobuz credential file could not be loaded and will be quarantined",
                metadata: ["credentialsConfigured": "unknown"],
                error: error
            )
            do {
                let rejectedURL = try files.quarantine(
                    .credentials,
                    rejectedPrefix: "credentials.rejected"
                )
                qobuzLog.notice(
                    "persistence.credentials",
                    "Unreadable Qobuz credential file was quarantined",
                    metadata: [
                        "credentialsConfigured": "false",
                        "rejectedPath": rejectedURL.path
                    ]
                )
                return nil
            } catch let quarantineError {
                qobuzLog.error(
                    "persistence.credentials",
                    "Unreadable Qobuz credential file could not be quarantined",
                    error: quarantineError
                )
                throw error
            }
        }
    }

    func save(_ credentials: CredentialDraft) throws {
        try files.write(JSONEncoder.pretty.encode(credentials), to: .credentials)
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

    static var persistence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
