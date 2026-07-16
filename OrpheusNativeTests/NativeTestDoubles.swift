import Foundation
import NativeQobuzCore
@testable import OrpheusNative

struct MemoryCredentialStore: NativeCredentialStoring {
    var credentials: CredentialDraft?

    init(credentials: CredentialDraft? = nil) {
        self.credentials = credentials
    }

    func load() throws -> CredentialDraft? { credentials }
    func save(_ credentials: CredentialDraft) throws {}
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

    init(snapshot: QobuzArchiveSnapshot? = nil) {
        stored = snapshot
    }

    var snapshot: QobuzArchiveSnapshot? {
        lock.withLock { stored }
    }

    func load() throws -> NativeArchiveIndexLoadResult {
        lock.withLock { stored.map(NativeArchiveIndexLoadResult.restored) ?? .missing }
    }

    func save(_ snapshot: QobuzArchiveSnapshot) throws {
        lock.withLock { stored = snapshot }
    }
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
}
