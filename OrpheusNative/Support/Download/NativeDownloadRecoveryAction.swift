enum NativeDownloadRecoveryAction {
    case resume
    case retry

    var permission: KeyPath<NativeDownloadStatus, Bool> {
        switch self {
        case .resume: \.canResume
        case .retry: \.canRetry
        }
    }

    var logMessage: String {
        switch self {
        case .resume: "User requested download resume"
        case .retry: "User requested download retry"
        }
    }
}
