import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileDialog {
    static func chooseLinksFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText] + ["m3u", "m3u8"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseFolder(startingAt path: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
