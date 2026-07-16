import Foundation
import NativeQobuzCore
@testable import OrpheusNative

final class NativeViewModelTestFixture {
    let root: URL
    let paths: NativePaths
    let viewModel: NativeViewModel

    @MainActor init(
        credentials: CredentialDraft? = nil,
        service: any NativeQobuzServicing = FakeQobuzService(),
        sessionStore: (any NativeSessionStoring)? = nil,
        archiveStore: (any NativeArchiveIndexStoring)? = nil
    ) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        paths = NativePaths(
            applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
            defaultDownloadRoot: root.appendingPathComponent("Music", isDirectory: true)
        )
        viewModel = NativeViewModel(
            paths: paths,
            settingsStore: NativeSettingsStore(paths: paths),
            credentialStore: MemoryCredentialStore(credentials: credentials),
            archiveStore: archiveStore,
            sessionStore: sessionStore,
            clientFactory: { _ in service }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

func singleItemSession(
    item: NativeQueueItem,
    operation: NativeDownloadOperation
) -> NativeSessionSnapshot {
    NativeSessionSnapshot(
        queue: [item],
        operations: [operation],
        selectedQueueID: item.id,
        linkInbox: []
    )
}

func twoTrackQueuePlan() -> [NativeQueueTrack] {
    [
        NativeQueueTrack(
            id: "one#0",
            qobuzID: QobuzID("one"),
            title: "One",
            subtitle: "Artist",
            duration: 180,
            position: 1,
            unavailableReason: nil
        ),
        NativeQueueTrack(
            id: "two#1",
            qobuzID: QobuzID("two"),
            title: "Two",
            subtitle: "Artist",
            duration: 200,
            position: 2,
            unavailableReason: nil
        )
    ]
}
