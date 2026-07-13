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
}

protocol NativeDataMigrating: Sendable {
    func migrateIfNeeded() throws
}

struct NoOpNativeDataMigrator: NativeDataMigrating {
    func migrateIfNeeded() throws {}
}

struct NativePreviewDataMigrator: NativeDataMigrating, @unchecked Sendable {
    static let markerName = ".migration-v1-from-native-preview"

    let sourceRoot: URL
    let destinationRoot: URL
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            sourceRoot: support.appendingPathComponent("OrpheusNativePreview", isDirectory: true),
            destinationRoot: support.appendingPathComponent("Orpheus for Mac", isDirectory: true),
            fileManager: fileManager
        )
    }

    init(sourceRoot: URL, destinationRoot: URL, fileManager: FileManager = .default) {
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.fileManager = fileManager
    }

    func migrateIfNeeded() throws {
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceRoot.path, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else { return }

        let marker = destinationRoot.appendingPathComponent(Self.markerName)
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        if !fileManager.fileExists(atPath: destinationRoot.path) {
            try installCompleteCopy()
        } else {
            try mergeMissingItems(marker: marker)
        }
        try secureMigratedCredentials()
    }

    private func installCompleteCopy() throws {
        let parent = destinationRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".orpheus-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: sourceRoot, to: staging)
        try writeMarker(at: staging.appendingPathComponent(Self.markerName))
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try fileManager.moveItem(at: staging, to: destinationRoot)
    }

    private func mergeMissingItems(marker: URL) throws {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for source in try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) {
            if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.copyItem(at: source, to: destination)
        }
        try writeMarker(at: marker)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationRoot.path)
    }

    private func writeMarker(at url: URL) throws {
        try Data("Orpheus Native Preview migration v1\n".utf8).write(to: url, options: .atomic)
    }

    private func secureMigratedCredentials() throws {
        let credentials = destinationRoot.appendingPathComponent("credentials.json")
        guard fileManager.fileExists(atPath: credentials.path) else { return }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentials.path)
    }
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

protocol NativeArchiveIndexStoring: Sendable {
    func load() throws -> QobuzArchiveSnapshot?
    func save(_ snapshot: QobuzArchiveSnapshot) throws
}

struct NativeArchiveIndexStore: NativeArchiveIndexStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths = NativePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> QobuzArchiveSnapshot? {
        guard fileManager.fileExists(atPath: paths.archiveIndexURL.path) else { return nil }
        let snapshot = try JSONDecoder().decode(
            QobuzArchiveSnapshot.self,
            from: Data(contentsOf: paths.archiveIndexURL)
        )
        guard snapshot.version == 1 else {
            throw NativeQobuzError.invalidResponse("Unsupported archive index version.")
        }
        return snapshot
    }

    func save(_ snapshot: QobuzArchiveSnapshot) throws {
        try fileManager.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(snapshot).write(to: paths.archiveIndexURL, options: .atomic)
    }
}

struct NativeSessionSnapshot: Codable, Equatable {
    let version: Int
    var queue: [NativeQueueItem]
    var activities: [NativeDownloadActivity]
    var selectedQueueID: UUID?
    var linkInbox: [NativeLinkInboxItem]

    init(
        version: Int = 2,
        queue: [NativeQueueItem],
        activities: [NativeDownloadActivity],
        selectedQueueID: UUID?,
        linkInbox: [NativeLinkInboxItem] = []
    ) {
        self.version = version
        self.queue = queue
        self.activities = activities
        self.selectedQueueID = selectedQueueID
        self.linkInbox = linkInbox
    }

    private enum CodingKeys: String, CodingKey {
        case version, queue, activities, selectedQueueID, linkInbox
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        queue = try container.decode([NativeQueueItem].self, forKey: .queue)
        activities = try container.decode([NativeDownloadActivity].self, forKey: .activities)
        selectedQueueID = try container.decodeIfPresent(UUID.self, forKey: .selectedQueueID)
        linkInbox = try container.decodeIfPresent([NativeLinkInboxItem].self, forKey: .linkInbox) ?? []
    }
}

protocol NativeSessionStoring: Sendable {
    func load() throws -> NativeSessionSnapshot?
    func save(_ snapshot: NativeSessionSnapshot) throws
}

struct NativeSessionStore: NativeSessionStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths = NativePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> NativeSessionSnapshot? {
        guard fileManager.fileExists(atPath: paths.sessionURL.path) else { return nil }
        let snapshot = try JSONDecoder().decode(
            NativeSessionSnapshot.self,
            from: Data(contentsOf: paths.sessionURL)
        )
        guard (1...2).contains(snapshot.version) else {
            throw NativeQobuzError.invalidResponse("Unsupported download session version.")
        }
        return snapshot
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        try fileManager.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(snapshot).write(to: paths.sessionURL, options: .atomic)
    }
}

protocol NativeCredentialStoring: Sendable {
    func load() throws -> CredentialDraft?
    func save(_ credentials: CredentialDraft) throws
}

struct FileCredentialStore: NativeCredentialStoring, @unchecked Sendable {
    let paths: NativePaths
    let fileManager: FileManager

    init(paths: NativePaths = NativePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> CredentialDraft? {
        guard fileManager.fileExists(atPath: paths.credentialsURL.path) else { return nil }
        return try JSONDecoder().decode(
            CredentialDraft.self,
            from: Data(contentsOf: paths.credentialsURL)
        )
    }

    func save(_ credentials: CredentialDraft) throws {
        try fileManager.createDirectory(at: paths.applicationSupportRoot, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.applicationSupportRoot.path
        )
        try JSONEncoder.pretty.encode(credentials).write(to: paths.credentialsURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.credentialsURL.path
        )
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
