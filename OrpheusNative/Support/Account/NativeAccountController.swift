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

    private let configurationStore: any NativeConfigurationStoring
    private let clientFactory: (QobuzCredentials) -> any NativeQobuzServicing
    private var credentialRevision: UInt64 = 0
    private var validationID: UUID?

    private(set) var client: (any NativeQobuzServicing)?

    init(
        paths: NativePaths,
        configurationStore: (any NativeConfigurationStoring)? = nil,
        clientFactory: @escaping (QobuzCredentials) -> any NativeQobuzServicing
    ) {
        self.configurationStore = configurationStore ?? NativeConfigurationStore(paths: paths)
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

    func load() async throws {
        let configurationStore = configurationStore
        let loaded = try await Task.detached(priority: .userInitiated) {
            try configurationStore.load()
        }.value
        try Task.checkCancellation()
        settings = loaded.settings
        credentials = loaded.credentials
        credentialRevision &+= 1
        validationID = nil
        configureClient()
        qobuzLog.info(
            "account.configuration",
            "Account configuration loaded",
            metadata: [
                "credentialsConfigured": String(loaded.credentials.isComplete),
                "downloadPath": loaded.settings.downloadPath,
                "quality": loaded.settings.quality.rawValue
            ]
        )
    }

    @discardableResult
    func save(
        _ draft: SettingsDraft,
        downloadIsActive: Bool,
        downloadRootMutationBlocked: Bool = false
    ) throws -> NativeConfigurationChange {
        try save(
            credentials: draft.credentials,
            settings: NativeSettings(downloadPath: draft.downloadPath, quality: draft.quality),
            downloadIsActive: downloadIsActive,
            downloadRootMutationBlocked: downloadRootMutationBlocked
        )
    }

    @discardableResult
    func save(
        credentials: CredentialDraft,
        settings: NativeSettings,
        downloadIsActive: Bool,
        downloadRootMutationBlocked: Bool = false
    ) throws -> NativeConfigurationChange {
        guard !downloadIsActive else {
            qobuzLog.warning("settings", "Settings change blocked during an active download")
            throw NativeQobuzError.unavailable("Settings cannot change during a download.")
        }

        let settings = try settings.normalized()
        let previousSettings = self.settings
        let change = NativeConfigurationChange(
            downloadRootChanged: previousSettings.downloadPath != settings.downloadPath,
            credentialsChanged: self.credentials != credentials
        )
        guard !change.downloadRootChanged || !downloadRootMutationBlocked else {
            qobuzLog.warning(
                "settings",
                "Download root change blocked by Library or recovery work",
                metadata: ["currentDownloadPath": previousSettings.downloadPath]
            )
            throw NativeQobuzError.unavailable(
                "The download location cannot change while Library work or a recoverable download still refers to it."
            )
        }
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
            try configurationStore.save(NativeConfiguration(
                settings: settings,
                credentials: credentials
            ))
            self.settings = settings
            self.credentials = credentials
            if change.credentialsChanged {
                credentialRevision &+= 1
                validationID = nil
                accountRegion = nil
                configureClient()
            }
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
        let currentValidationID = UUID()
        let revision = credentialRevision
        validationID = currentValidationID
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
            try Task.checkCancellation()
            guard validationID == currentValidationID, credentialRevision == revision else {
                qobuzLog.debug(
                    "account.connection",
                    "Discarded a superseded Qobuz connection result",
                    metadata: ["connectionTestID": testID]
                )
                throw NativeQobuzError.cancelled
            }
            validationID = nil
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
            guard validationID == currentValidationID, credentialRevision == revision else {
                qobuzLog.debug(
                    "account.connection",
                    "Discarded a superseded Qobuz connection failure",
                    metadata: ["connectionTestID": testID]
                )
                throw NativeQobuzError.cancelled
            }
            validationID = nil
            if error.isQobuzCancellation {
                qobuzLog.debug(
                    "account.connection",
                    "Qobuz connection test cancelled",
                    metadata: ["connectionTestID": testID]
                )
                throw error
            }
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

    func cancelValidation() {
        validationID = nil
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
