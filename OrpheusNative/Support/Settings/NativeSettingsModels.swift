import Foundation
import NativeQobuzCore

struct NativeSettings: Codable, Equatable {
    var downloadPath: String
    var quality: QobuzQuality

    func normalized() throws -> NativeSettings {
        guard !downloadPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (downloadPath as NSString).isAbsolutePath else {
            throw NativeSettingsValidationError.invalidDownloadPath
        }
        return NativeSettings(
            downloadPath: URL(fileURLWithPath: downloadPath, isDirectory: true)
                .standardizedFileURL.path,
            quality: quality
        )
    }
}

enum NativeSettingsValidationError: LocalizedError, Equatable {
    case invalidDownloadPath

    var errorDescription: String? {
        switch self {
        case .invalidDownloadPath:
            "The download location must be a non-empty absolute folder path."
        }
    }
}

struct CredentialDraft: Codable, Equatable {
    var appID = ""
    var appSecret = ""
    var authToken = ""

    var coreValue: QobuzCredentials {
        QobuzCredentials(appID: appID, appSecret: appSecret, authToken: authToken)
    }

    var isComplete: Bool { coreValue.isComplete }
}

/// Editable copy of the configuration shown in the settings sheet.
struct SettingsDraft: Equatable {
    var credentials = CredentialDraft()
    var quality: QobuzQuality = .hiRes
    var downloadPath = ""
}
