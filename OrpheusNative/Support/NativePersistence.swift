import Foundation
import Security

struct NativePaths: Sendable {
    let applicationSupportRoot: URL
    let defaultDownloadRoot: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        applicationSupportRoot = support.appendingPathComponent("OrpheusNativePreview", isDirectory: true)
        defaultDownloadRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Orpheus Native Preview", isDirectory: true)
    }

    init(applicationSupportRoot: URL, defaultDownloadRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaultDownloadRoot = defaultDownloadRoot
    }

    var settingsURL: URL { applicationSupportRoot.appendingPathComponent("settings.json") }
}

protocol NativeSettingsStoring: Sendable {
    func load() throws -> NativeSettings
    func save(_ settings: NativeSettings) throws
}

struct NativeSettingsStore: NativeSettingsStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths = NativePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> NativeSettings {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            let value = NativeSettings(downloadPath: paths.defaultDownloadRoot.path, quality: .hiRes)
            try save(value)
            return value
        }
        return try JSONDecoder().decode(NativeSettings.self, from: Data(contentsOf: paths.settingsURL))
    }

    func save(_ settings: NativeSettings) throws {
        try fileManager.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: paths.settingsURL, options: .atomic)
    }
}

protocol NativeCredentialStoring: Sendable {
    func load() throws -> CredentialDraft?
    func save(_ credentials: CredentialDraft) throws
}

struct KeychainCredentialStore: NativeCredentialStoring, Sendable {
    private let service = "com.orpheus.native.preview.qobuz"
    private let account = "credentials"

    func load() throws -> CredentialDraft? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status) }
        return try JSONDecoder().decode(CredentialDraft.self, from: data)
    }

    func save(_ credentials: CredentialDraft) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
