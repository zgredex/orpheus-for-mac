import Foundation
import NativeQobuzCore
#if !ORPHEUS_UNHOSTED_TESTS
@testable import OrpheusNative
#endif

extension CredentialDraft {
    static let complete = CredentialDraft(
        appID: "app-id",
        appSecret: "app-secret",
        authToken: "token"
    )
}

final class MemoryConfigurationStore: NativeConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeConfiguration
    private var failSave = false
    private var writes = 0

    init(
        paths: NativePaths,
        credentials: CredentialDraft? = nil,
        settings: NativeSettings? = nil
    ) {
        stored = NativeConfiguration(
            settings: settings ?? NativeSettings(
                downloadPath: paths.defaultDownloadRoot.path,
                quality: .hiRes
            ),
            credentials: credentials ?? CredentialDraft()
        )
    }

    var configuration: NativeConfiguration { lock.withLock { stored } }
    var saveCount: Int { lock.withLock { writes } }

    func failNextSave() {
        lock.withLock { failSave = true }
    }

    func load() throws -> NativeConfiguration { configuration }

    func save(_ configuration: NativeConfiguration) throws {
        try lock.withLock {
            if failSave {
                failSave = false
                throw MemoryStoreFailure.injected
            }
            stored = configuration
            writes += 1
        }
    }
}

@MainActor
final class FakeConnectivityMonitor: NativeConnectivityMonitoring {
    private(set) var state: NativeConnectivityState = .unknown
    private var handler: ((NativeConnectivityState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onChange: @escaping @MainActor (NativeConnectivityState) -> Void) {
        startCount += 1
        handler = onChange
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ state: NativeConnectivityState) {
        self.state = state
        handler?(state)
    }
}

@MainActor
final class FakePowerActivityManager: NativePowerActivityManaging {
    private(set) var beginReasons: [String] = []
    private(set) var endCount = 0

    func begin(reason: String) -> NSObjectProtocol {
        beginReasons.append(reason)
        return NSObject()
    }

    func end(_ token: NSObjectProtocol) {
        endCount += 1
    }
}

final class MemoryArchiveStore: NativeArchiveIndexStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: QobuzArchiveSnapshot?
    private var failSave = false
    private var failRemoval = false

    init(snapshot: QobuzArchiveSnapshot? = nil) {
        stored = snapshot
    }

    var snapshot: QobuzArchiveSnapshot? {
        lock.withLock { stored }
    }

    func failNextSave() {
        lock.withLock { failSave = true }
    }

    func failNextRemoval() {
        lock.withLock { failRemoval = true }
    }

    func load() throws -> NativeArchiveIndexLoadResult {
        lock.withLock { stored.map(NativeArchiveIndexLoadResult.restored) ?? .missing }
    }

    func save(_ snapshot: QobuzArchiveSnapshot) throws {
        try lock.withLock {
            if failSave {
                failSave = false
                throw MemoryStoreFailure.injected
            }
            stored = snapshot
        }
    }

    func remove() throws {
        try lock.withLock {
            if failRemoval {
                failRemoval = false
                throw MemoryStoreFailure.injected
            }
            stored = nil
        }
    }
}

enum MemoryStoreFailure: Error {
    case injected
}

final class MemorySessionStore: NativeSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeSessionSnapshot?

    init(snapshot: NativeSessionSnapshot? = nil) {
        stored = snapshot
    }

    var snapshot: NativeSessionSnapshot? {
        lock.withLock { stored }
    }

    func load() throws -> NativeSessionSnapshot? {
        lock.withLock { stored }
    }

    func save(_ snapshot: NativeSessionSnapshot) throws {
        lock.withLock { stored = snapshot }
    }

    func rejectLoadedSnapshot(cause: Error) throws {
        lock.withLock { stored = nil }
    }
}

struct StubSupplementalDiagnosticsCollector: NativeSupplementalDiagnosticsCollecting {
    func collect(into bundleRoot: URL) -> NativeSupplementalDiagnosticSummary {
        NativeSupplementalDiagnosticSummary(
            generatedAt: Date(timeIntervalSince1970: 0),
            currentProcessUnifiedLog: NativeDiagnosticArtifactStatus(
                state: .empty,
                itemCount: 0,
                relativePath: nil,
                messages: []
            ),
            crashReports: NativeDiagnosticArtifactStatus(
                state: .empty,
                itemCount: 0,
                relativePath: nil,
                messages: []
            ),
            systemWideUnifiedLogIncluded: false
        )
    }
}
