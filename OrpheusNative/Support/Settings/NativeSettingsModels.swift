import Foundation
import NativeQobuzCore

struct NativeSettings: Codable, Equatable {
    var downloadPath: String
    var quality: QobuzQuality
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
