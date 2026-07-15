import Foundation

struct QobuzDeliveryPolicy: Sendable {
    func notice(
        for item: QobuzResolvedTrack,
        requestedMaximum: QobuzQuality,
        delivered fileInfo: QobuzFileInfo
    ) -> String? {
        guard fileInfo.format != requestedMaximum.maximumFormat || !fileInfo.restrictions.isEmpty else {
            return nil
        }
        let reason = fileInfo.restrictions.first.map(restrictionDescription)
            ?? "Qobuz selected the highest available quality below the configured maximum."
        return "\(item.track.displayTitle) — \(fileInfo.format.displayName) delivered under the \(requestedMaximum.maximumFormat.displayName) maximum. \(reason)"
    }

    private func restrictionDescription(_ restriction: QobuzFileRestriction) -> String {
        if let message = restriction.message, !message.isEmpty { return message }
        switch restriction.code {
        case "FormatRestrictedByFormatAvailability":
            return "The configured maximum is not available for this track."
        default:
            return "Qobuz reported restriction \(restriction.code)."
        }
    }
}
