import AppKit
import Foundation

protocol FinderRevealing: AnyObject {
    func reveal(urls: [URL])
}

final class WorkspaceFinderRevealer: FinderRevealing {
    func reveal(urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

struct DownloadOutputResolver {
    let fileManager: FileManager

    func resolveOutput(in root: URL, startedAt: Date) -> URL? {
        let cutoff = startedAt.addingTimeInterval(-2)
        guard let candidates = try? candidates(in: root, cutoff: cutoff), !candidates.isEmpty else {
            return nil
        }

        if let direct = candidates
            .filter({ $0.isDirectChild })
            .max(by: { $0.date < $1.date }) {
            return direct.url
        }

        return candidates.max(by: { $0.date < $1.date })?.url
    }

    private func candidates(in root: URL, cutoff: Date) throws -> [OutputCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isHiddenKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let standardizedRoot = root.standardizedFileURL
        var output: [OutputCandidate] = []

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isHiddenKey
            ])
            if values.isHidden == true { continue }

            let date = [values.contentModificationDate, values.creationDate]
                .compactMap { $0 }
                .max()
            guard let date, date >= cutoff else { continue }

            output.append(OutputCandidate(
                url: url,
                date: date,
                isDirectChild: url.deletingLastPathComponent().standardizedFileURL.path == standardizedRoot.path
            ))
        }

        return output
    }

    private struct OutputCandidate {
        let url: URL
        let date: Date
        let isDirectChild: Bool
    }
}
