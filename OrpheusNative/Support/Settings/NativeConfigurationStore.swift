import Foundation
import NativeQobuzCore

/// The complete persisted user configuration. Settings and credentials share
/// one atomic file so the running client can never observe a mixed revision.
struct NativeConfiguration: Codable, Equatable, Sendable {
    let settings: NativeSettings
    let credentials: CredentialDraft

    func normalized() throws -> NativeConfiguration {
        NativeConfiguration(settings: try settings.normalized(), credentials: credentials)
    }

    static func fresh(paths: NativePaths) -> NativeConfiguration {
        NativeConfiguration(
            settings: NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes),
            credentials: CredentialDraft()
        )
    }
}

protocol NativeConfigurationStoring: Sendable {
    func load() throws -> NativeConfiguration
    func save(_ configuration: NativeConfiguration) throws
}

struct NativeConfigurationStore: NativeConfigurationStoring, Sendable {
    let paths: NativePaths
    private let files: NativeApplicationSupportFileStore

    init(paths: NativePaths) {
        self.paths = paths
        files = NativeApplicationSupportFileStore(rootURL: paths.applicationSupportRoot)
    }

    func load() throws -> NativeConfiguration {
        do {
            guard let data = try files.read(.configuration) else {
                return try createFresh(reason: "No configuration file exists")
            }
            let configuration = try JSONDecoder().decode(
                NativeConfiguration.self,
                from: data
            ).normalized()
            logLoaded(configuration)
            return configuration
        } catch {
            qobuzLog.error(
                "persistence.configuration",
                "Configuration could not be loaded and will be quarantined",
                metadata: ["configurationPath": paths.configurationURL.path],
                error: error
            )
            do {
                let rejectedURL = try files.quarantine(
                    .configuration,
                    rejectedPrefix: "configuration.rejected"
                )
                qobuzLog.notice(
                    "persistence.configuration",
                    "Unreadable configuration was quarantined",
                    metadata: ["rejectedPath": rejectedURL.path]
                )
                return try createFresh(reason: "Unreadable configuration was quarantined")
            } catch let quarantineError {
                qobuzLog.error(
                    "persistence.configuration",
                    "Unreadable configuration could not be quarantined",
                    error: quarantineError
                )
                throw error
            }
        }
    }

    func save(_ configuration: NativeConfiguration) throws {
        let configuration = try configuration.normalized()
        try files.write(JSONEncoder.pretty.encode(configuration), to: .configuration)
        qobuzLog.notice(
            "persistence.configuration",
            "Atomic app configuration saved with owner-only permissions",
            metadata: metadata(for: configuration)
        )
    }

    private func createFresh(reason: String) throws -> NativeConfiguration {
        let configuration = NativeConfiguration.fresh(paths: paths)
        try save(configuration)
        qobuzLog.notice(
            "persistence.configuration",
            "Fresh app configuration created",
            metadata: ["configurationPath": paths.configurationURL.path, "reason": reason]
        )
        return configuration
    }

    private func logLoaded(_ configuration: NativeConfiguration) {
        qobuzLog.info(
            "persistence.configuration",
            "App configuration loaded",
            metadata: metadata(for: configuration)
        )
    }

    private func metadata(for configuration: NativeConfiguration) -> [String: String] {
        [
            "configurationPath": paths.configurationURL.path,
            "credentialsConfigured": String(configuration.credentials.isComplete),
            "downloadPath": configuration.settings.downloadPath,
            "quality": configuration.settings.quality.rawValue
        ]
    }
}
