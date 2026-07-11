import Foundation

struct RuntimeLocator {
    enum RuntimeError: LocalizedError {
        case missingBundledTemplate([String])
        case missingHelper(URL)

        var errorDescription: String? {
            switch self {
            case .missingBundledTemplate(let candidates):
                return "Cannot find the bundled OrpheusDL template. Checked: \(candidates.joined(separator: ", "))"
            case .missingHelper(let url):
                return "Cannot find the bundled Orpheus helper at \(url.path). Build the portable package first."
            }
        }
    }

    let fileManager: FileManager
    let bundle: Bundle
    let applicationSupportRoot: URL
    let defaultDownloadURL: URL
    private let resourceOverrideURL: URL?
    private let templateOverrideURL: URL?
    private let helperOverrideURL: URL?

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        applicationSupportRoot: URL? = nil,
        defaultDownloadURL: URL? = nil,
        resourceURL: URL? = nil,
        templateURL: URL? = nil,
        helperURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.resourceOverrideURL = resourceURL
        self.templateOverrideURL = templateURL
        self.helperOverrideURL = helperURL

        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let supportBase = applicationSupportRoot
            ?? supportDirectory.appendingPathComponent("OrpheusUI", isDirectory: true)
        self.applicationSupportRoot = supportBase

        let music = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        self.defaultDownloadURL = defaultDownloadURL
            ?? music.appendingPathComponent("OrpheusUI", isDirectory: true)
    }

    var runtimeProjectURL: URL {
        applicationSupportRoot.appendingPathComponent("OrpheusDL", isDirectory: true)
    }

    var settingsURL: URL {
        runtimeProjectURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    var logURL: URL {
        applicationSupportRoot.appendingPathComponent("orpheus-ui.log")
    }

    var helperURL: URL {
        if let helperOverrideURL {
            return helperOverrideURL
        }
        if let resourceURL = resolvedResourceURL {
            let onedir = resourceURL
                .appendingPathComponent("orpheus-helper", isDirectory: true)
                .appendingPathComponent("orpheus-helper")
            if fileManager.isExecutableFile(atPath: onedir.path) {
                return onedir
            }

            let legacy = resourceURL.appendingPathComponent("orpheus-helper")
            if fileManager.isExecutableFile(atPath: legacy.path) {
                return legacy
            }
        }
        let resourceRoot = resolvedResourceURL
            ?? bundle.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        return resourceRoot
            .appendingPathComponent("orpheus-helper", isDirectory: true)
            .appendingPathComponent("orpheus-helper")
    }

    var ffmpegURL: URL? {
        guard let resourceURL = resolvedResourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("ffmpeg")
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private var resolvedResourceURL: URL? {
        resourceOverrideURL ?? bundle.resourceURL
    }

    func prepareRuntime() throws {
        try fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: defaultDownloadURL, withIntermediateDirectories: true)
        cleanupStaleStagingDirectories()

        guard fileManager.fileExists(atPath: settingsURL.path) else {
            let template = try resolveTemplateURL()
            try installRuntimeTemplate(from: template)
            return
        }

        guard let template = try? resolveTemplateURL() else {
            return
        }
        try refreshRuntimeTemplate(from: template)
    }

    func resolvedDownloadURL(from rawPath: String) -> URL {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return defaultDownloadURL
        }
        if path.hasPrefix("~/") {
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        if path.hasPrefix("./") || path.hasPrefix("../") {
            let candidate = runtimeProjectURL.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            let rootPath = runtimeProjectURL.standardizedFileURL.path
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
                return defaultDownloadURL
            }
            return candidate
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func verifyHelperExists() throws {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw RuntimeError.missingHelper(helperURL)
        }
    }

    private func resolveTemplateURL() throws -> URL {
        var candidates: [URL] = []
        if let templateOverrideURL {
            candidates.append(templateOverrideURL)
        }
        if let resourceURL = resolvedResourceURL {
            candidates.append(resourceURL.appendingPathComponent("OrpheusDLTemplate", isDirectory: true))
        }
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ORPHEUSDL_TEMPLATE_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw RuntimeError.missingBundledTemplate(candidates.map(\.path))
    }

    private func cleanupStaleStagingDirectories() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: applicationSupportRoot,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for child in children where
            child.lastPathComponent.hasPrefix(".OrpheusDL.staging.")
                || child.lastPathComponent.hasPrefix(".OrpheusDL.refresh.") {
            try? fileManager.removeItem(at: child)
        }
    }

    private func installRuntimeTemplate(from template: URL) throws {
        let stagingURL = applicationSupportRoot
            .appendingPathComponent(".OrpheusDL.staging.\(UUID().uuidString)", isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try copyRuntimeTemplate(from: template, to: stagingURL)
        try sanitizeCopiedSettings(in: stagingURL)
        try commitStagedRuntime(from: stagingURL)
    }

    private func refreshRuntimeTemplate(from template: URL) throws {
        let stagingURL = applicationSupportRoot
            .appendingPathComponent(".OrpheusDL.refresh.\(UUID().uuidString)", isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try copyRuntimeTemplate(from: template, to: stagingURL)
        try preserveMutableRuntimeFiles(from: runtimeProjectURL, to: stagingURL)
        try commitStagedRuntime(from: stagingURL)
    }

    private func sanitizeCopiedSettings(in runtimeURL: URL) throws {
        let copiedSettingsURL = settingsURL(in: runtimeURL)
        guard fileManager.fileExists(atPath: copiedSettingsURL.path) else { return }

        var settings = try SettingsStore.load(from: copiedSettingsURL)
        settings.stripLocalCredentials(
            defaultDownloadPath: defaultDownloadURL.path,
            disableConversions: ffmpegURL == nil
        )
        try SettingsStore.save(settings, to: copiedSettingsURL)
    }

    private func commitStagedRuntime(from stagingURL: URL) throws {
        if fileManager.fileExists(atPath: runtimeProjectURL.path) {
            _ = try fileManager.replaceItemAt(
                runtimeProjectURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: runtimeProjectURL)
        }
    }

    private func settingsURL(in runtimeURL: URL) -> URL {
        runtimeURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func preserveMutableRuntimeFiles(from existingRuntime: URL, to stagingURL: URL) throws {
        let mutableRelativePaths = [
            "config/settings.json",
            "config/loginstorage.bin",
            "downloads",
            "temp"
        ]

        for relativePath in mutableRelativePaths {
            let source = existingRuntime.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let target = stagingURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
        }
    }

    private func copyRuntimeTemplate(from source: URL, to destination: URL) throws {
        let excludedNames: Set<String> = [
            ".DS_Store",
            ".git",
            "__pycache__",
            "downloads",
            "temp"
        ]
        let excludedRelativePaths: Set<String> = [
            "config/loginstorage.bin"
        ]

        let sourcePath = source.standardizedFileURL.path
        let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(sourcePath + "/") else {
                enumerator?.skipDescendants()
                continue
            }
            let relativePath = String(itemPath.dropFirst(sourcePath.count + 1))
            if excludedNames.contains(name) || excludedRelativePaths.contains(relativePath) {
                enumerator?.skipDescendants()
                continue
            }

            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            let target = destination.appendingPathComponent(relativePath, isDirectory: resourceValues.isDirectory == true)
            if resourceValues.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }
}
