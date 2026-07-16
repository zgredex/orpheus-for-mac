import Foundation
import NativeQobuzCore

struct NativeConfigurationChange: Equatable {
    let downloadRootChanged: Bool
    let credentialsChanged: Bool
}

@MainActor
final class NativeAccountController: ObservableObject {
    @Published private(set) var settings: NativeSettings
    @Published private(set) var credentials = CredentialDraft()
    @Published private(set) var accountRegion: String?

    private let settingsStore: any NativeSettingsStoring
    private let credentialStore: any NativeCredentialStoring
    private let clientFactory: (QobuzCredentials) -> any NativeQobuzServicing

    private(set) var client: (any NativeQobuzServicing)?

    init(
        paths: NativePaths,
        settingsStore: (any NativeSettingsStoring)? = nil,
        credentialStore: (any NativeCredentialStoring)? = nil,
        clientFactory: @escaping (QobuzCredentials) -> any NativeQobuzServicing
    ) {
        self.settingsStore = settingsStore ?? NativeSettingsStore(paths: paths)
        self.credentialStore = credentialStore ?? FileCredentialStore(paths: paths)
        self.clientFactory = clientFactory
        settings = NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes)
    }

    var isConfigured: Bool { credentials.isComplete }
    var downloadRoot: URL { URL(fileURLWithPath: settings.downloadPath, isDirectory: true).standardizedFileURL }

    var draft: SettingsDraft {
        SettingsDraft(
            credentials: credentials,
            quality: settings.quality,
            downloadPath: settings.downloadPath
        )
    }

    var regionDisplay: String {
        guard let accountRegion else { return "Qobuz" }
        guard let flag = CountryFlag.emoji(for: accountRegion) else { return accountRegion }
        return "\(flag) \(accountRegion.uppercased())"
    }

    func load() throws {
        let loadedSettings = try settingsStore.load()
        let loadedCredentials = try credentialStore.load() ?? CredentialDraft()
        settings = loadedSettings
        credentials = loadedCredentials
        configureClient()
        qobuzLog.info(
            "account.configuration",
            "Account configuration loaded",
            metadata: [
                "credentialsConfigured": String(loadedCredentials.isComplete),
                "downloadPath": loadedSettings.downloadPath,
                "quality": loadedSettings.quality.rawValue
            ]
        )
    }

    @discardableResult
    func save(_ draft: SettingsDraft, downloadIsActive: Bool) throws -> NativeConfigurationChange {
        try save(
            credentials: draft.credentials,
            settings: NativeSettings(downloadPath: draft.downloadPath, quality: draft.quality),
            downloadIsActive: downloadIsActive
        )
    }

    @discardableResult
    func save(
        credentials: CredentialDraft,
        settings: NativeSettings,
        downloadIsActive: Bool
    ) throws -> NativeConfigurationChange {
        guard !downloadIsActive else {
            qobuzLog.warning("settings", "Settings change blocked during an active download")
            throw NativeQobuzError.unavailable("Settings cannot change during a download.")
        }

        let change = NativeConfigurationChange(
            downloadRootChanged: self.settings.downloadPath != settings.downloadPath,
            credentialsChanged: self.credentials != credentials
        )
        qobuzLog.notice(
            "settings",
            "Saving app configuration",
            metadata: [
                "downloadPath": settings.downloadPath,
                "quality": settings.quality.rawValue,
                "rootChanged": String(change.downloadRootChanged),
                "credentialsChanged": String(change.credentialsChanged),
                "credentialsConfigured": String(credentials.isComplete)
            ]
        )

        do {
            try settingsStore.save(settings)
            try credentialStore.save(credentials)
            self.settings = settings
            self.credentials = credentials
            if change.credentialsChanged { accountRegion = nil }
            configureClient()
            qobuzLog.notice("settings", "App configuration saved")
            return change
        } catch {
            qobuzLog.error("settings", "App configuration could not be saved", error: error)
            throw error
        }
    }

    @discardableResult
    func validateConnection() async throws -> String? {
        guard let client else {
            qobuzLog.warning(
                "account.connection",
                "Qobuz connection test blocked because credentials are incomplete",
                metadata: ["credentialsConfigured": "false"]
            )
            throw NativeQobuzError.unavailable("Enter complete Qobuz credentials first.")
        }

        let testID = UUID().uuidString
        let startedAt = Date()
        qobuzLog.info(
            "account.connection",
            "Qobuz connection test started",
            metadata: ["connectionTestID": testID]
        )
        do {
            let region = try await QobuzLogScope.withValue(["connectionTestID": testID]) {
                try await client.validateAccount()
            }
            accountRegion = region
            qobuzLog.notice(
                "account.connection",
                "Qobuz connection test succeeded",
                metadata: [
                    "connectionTestID": testID,
                    "accountRegion": region ?? "unknown",
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ]
            )
            return region
        } catch {
            accountRegion = nil
            qobuzLog.error(
                "account.connection",
                "Qobuz connection test failed",
                metadata: [
                    "connectionTestID": testID,
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ],
                error: error
            )
            throw error
        }
    }

    private func configureClient() {
        client = credentials.isComplete ? clientFactory(credentials.coreValue) : nil
        qobuzLog.info(
            "account.client",
            "Qobuz client configuration updated",
            metadata: [
                "credentialsConfigured": String(credentials.isComplete),
                "clientAvailable": String(client != nil)
            ]
        )
    }
}
