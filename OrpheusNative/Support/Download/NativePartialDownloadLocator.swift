import Foundation
import NativeQobuzCore

struct NativePartialDownloadLocator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func artifact(for activity: NativeDownloadActivity) -> NativePartialDownload? {
        guard let output = activity.outputURL,
              let format = activity.audioFormat ?? activity.quality?.maximumFormat else { return nil }
        let url = QobuzDownloadArtifacts.partialURL(for: output, formatID: format.formatID)
        guard fileManager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber,
              value.int64Value > 0 else { return nil }
        return NativePartialDownload(url: url, bytes: value.int64Value)
    }
}
