import NativeQobuzCore

/// Owns cross-domain policy for configuration changes without copying any of
/// the state held by the account, download, or Library controllers.
@MainActor
struct NativeConfigurationMutationCoordinator {
    private let account: NativeAccountController
    private let downloads: NativeDownloadController
    private let libraryManagement: NativeLibraryManagementController
    private let library: NativeLibraryController
    private let requirePermission: () throws -> Void

    init(
        account: NativeAccountController,
        downloads: NativeDownloadController,
        libraryManagement: NativeLibraryManagementController,
        library: NativeLibraryController,
        requirePermission: @escaping () throws -> Void
    ) {
        self.account = account
        self.downloads = downloads
        self.libraryManagement = libraryManagement
        self.library = library
        self.requirePermission = requirePermission
    }

    var isDownloadRootMutationBlocked: Bool {
        downloads.hasLibraryMutationConflict(at: account.downloadRoot)
            || libraryManagement.isWorking
            || library.isScanning
            || library.isPerformingAdoption
    }

    func save(_ draft: SettingsDraft) throws -> NativeConfigurationChange {
        try requirePermission()
        return try account.save(
            draft,
            downloadIsActive: downloads.isDownloading,
            downloadRootMutationBlocked: isDownloadRootMutationBlocked
        )
    }

    func save(
        credentials: CredentialDraft,
        settings: NativeSettings
    ) throws -> NativeConfigurationChange {
        try requirePermission()
        return try account.save(
            credentials: credentials,
            settings: settings,
            downloadIsActive: downloads.isDownloading,
            downloadRootMutationBlocked: isDownloadRootMutationBlocked
        )
    }
}
