import Foundation

/// Exact delivery facts that have been reconciled with the downloaded audio.
/// Construction is restricted to `QobuzDeliveryPolicy` so provenance cannot
/// accidentally trust API claims or filename extensions.
public struct QobuzValidatedAudioDelivery: Equatable, Sendable {
    public let format: QobuzAudioFormat
    public let container: AudioContainerFormat
    public let codec: AudioCodecFormat
    public let bitDepth: Int?
    public let samplingRate: Double

    fileprivate init(format: QobuzAudioFormat, media: AudioStreamProperties) {
        self.format = format
        container = media.container
        codec = media.codec
        bitDepth = media.bitDepth
        samplingRate = media.samplingRate
    }
}

/// Single authority for maximum-quality policy and delivered-media integrity.
public struct QobuzDeliveryPolicy: Sendable {
    public init() {}

    public func validateCeiling(
        requestedMaximum: QobuzQuality?,
        delivered fileInfo: QobuzFileInfo
    ) throws {
        guard let requestedMaximum else { return }
        let maximum = requestedMaximum.maximumFormat
        let maximumContract = maximum.deliveryContract
        let deliveredContract = fileInfo.format.deliveryContract
        guard deliveredContract.rank <= maximumContract.rank else {
            let metadata = [
                "requestedMaximum": requestedMaximum.rawValue,
                "requestedMaximumFormatID": String(maximum.formatID),
                "requestedMaximumRank": String(maximumContract.rank),
                "deliveredFormatID": String(fileInfo.formatID),
                "deliveredFormatRank": String(deliveredContract.rank)
            ]
            qobuzLog.error(
                "download.quality",
                "Qobuz delivered audio above the configured quality ceiling",
                metadata: metadata
            )
            throw NativeQobuzError.invalidResponse(
                "Qobuz delivered \(fileInfo.format.displayName), above the configured \(maximum.displayName) maximum."
            )
        }
    }

    public func validate(
        fileInfo: QobuzFileInfo,
        media: AudioStreamProperties
    ) throws -> QobuzValidatedAudioDelivery {
        let contract = fileInfo.format.deliveryContract
        let metadata = deliveryMetadata(fileInfo: fileInfo, media: media)

        guard media.container == contract.container else {
            throw inconsistency(
                "Qobuz format \(fileInfo.formatID) requires a \(contract.container.rawValue.uppercased()) container, but the downloaded file is \(media.container.rawValue.uppercased()).",
                metadata: metadata
            )
        }
        guard media.codec == contract.codec else {
            throw inconsistency(
                "Qobuz format \(fileInfo.formatID) requires the \(contract.codec.rawValue.uppercased()) codec, but the downloaded file uses \(media.codec.rawValue.uppercased()).",
                metadata: metadata
            )
        }
        guard media.samplingRate.isFinite, media.samplingRate > 0 else {
            throw inconsistency("Downloaded audio has no valid sample rate.", metadata: metadata)
        }
        if let bitDepth = media.bitDepth, bitDepth <= 0 {
            throw inconsistency("Downloaded audio has no valid bit depth.", metadata: metadata)
        }
        // MP3 has no meaningful encoded PCM bit depth. Qobuz may report a
        // nominal decoder depth, while the file itself correctly exposes none.
        if contract.bitDepth.isApplicable, let claimedDepth = fileInfo.bitDepth {
            guard claimedDepth > 0, media.bitDepth == claimedDepth else {
                throw inconsistency(
                    "Qobuz reported \(claimedDepth)-bit audio, but the downloaded file is \(media.bitDepth.map(String.init) ?? "unknown")-bit.",
                    metadata: metadata
                )
            }
        }
        if let claimedRate = fileInfo.samplingRate {
            guard claimedRate.isFinite, claimedRate > 0,
                  ratesMatch(claimedRate, media.samplingRate) else {
                throw inconsistency(
                    "Qobuz reported a \(claimedRate) kHz sample rate, but the downloaded file is \(media.samplingRate) kHz.",
                    metadata: metadata
                )
            }
        }

        guard contract.accepts(media) else {
            throw inconsistency(contract.inconsistencyDescription, metadata: metadata)
        }
        qobuzLog.notice(
            "download.delivery",
            "Downloaded audio properties match the Qobuz delivery",
            metadata: metadata
        )
        return QobuzValidatedAudioDelivery(format: fileInfo.format, media: media)
    }

    /// Validates an already archived file against its own immutable delivery
    /// record and decides whether it is safe to keep for the current request.
    /// A normal maximum-quality request may keep an equal or higher exact
    /// delivery below its ceiling; an exact repair may only keep the requested
    /// format. This prevents a temporary Qobuz fallback from downgrading a
    /// better file that is already in the Library.
    func validateExistingForReuse(
        provenance: QobuzFileProvenance,
        item: QobuzResolvedTrack,
        requestedMaximum: QobuzQuality?,
        offered fileInfo: QobuzFileInfo,
        media: AudioStreamProperties
    ) throws -> QobuzValidatedAudioDelivery {
        guard provenance.belongs(to: item),
              let archivedFormat = QobuzAudioFormat(formatID: provenance.formatID) else {
            throw NativeQobuzError.invalidResponse(
                "Existing file identity or archived Qobuz format is invalid."
            )
        }
        if let requestedMaximum {
            guard archivedFormat.deliveryContract.rank
                    <= requestedMaximum.maximumFormat.deliveryContract.rank else {
                throw NativeQobuzError.invalidResponse(
                    "Existing file is above the configured quality ceiling."
                )
            }
            guard archivedFormat.deliveryContract.rank >= fileInfo.format.deliveryContract.rank else {
                throw NativeQobuzError.invalidResponse(
                    "Qobuz currently offers a higher quality than the existing file."
                )
            }
        } else {
            guard archivedFormat == fileInfo.format else {
                throw NativeQobuzError.invalidResponse(
                    "Existing file does not match the exact repair format."
                )
            }
        }

        let archivedFileInfo = QobuzFileInfo(
            url: fileInfo.url,
            format: archivedFormat,
            bitDepth: provenance.bitDepth,
            samplingRate: provenance.samplingRate
        )
        let delivery = try validate(fileInfo: archivedFileInfo, media: media)
        guard provenance.matches(item: item, delivery: delivery) else {
            throw NativeQobuzError.invalidResponse(
                "Existing file properties do not match its archive provenance."
            )
        }
        return delivery
    }

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

    private func inconsistency(_ message: String, metadata: [String: String]) -> NativeQobuzError {
        qobuzLog.error(
            "download.delivery",
            "Downloaded audio is inconsistent with the Qobuz delivery",
            metadata: metadata.merging(["reason": message]) { _, new in new }
        )
        return .invalidResponse(message)
    }

    private func deliveryMetadata(
        fileInfo: QobuzFileInfo,
        media: AudioStreamProperties
    ) -> [String: String] {
        [
            "deliveredFormatID": String(fileInfo.formatID),
            "reportedBitDepth": fileInfo.bitDepth.map { String($0) } ?? "unknown",
            "reportedSamplingRateKHz": fileInfo.samplingRate.map { String($0) } ?? "unknown",
            "actualContainer": media.container.rawValue,
            "actualCodec": media.codec.rawValue,
            "actualBitDepth": media.bitDepth.map { String($0) } ?? "unknown",
            "actualSamplingRateKHz": String(media.samplingRate)
        ]
    }

    private func ratesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.01
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
