import Darwin
import NativeQobuzCore
import SwiftUI

@main
struct OrpheusNativeApp: App {
    @StateObject private var viewModel: NativeViewModel

    init() {
        _viewModel = StateObject(
            wrappedValue: NativeViewModel(dataMigrator: NativePreviewDataMigrator())
        )
        if ProcessInfo.processInfo.arguments.contains("--portability-smoke-test") {
            do {
                let validator = try FFmpegMediaValidator.bundled()
                guard FileManager.default.isExecutableFile(atPath: validator.executableURL.path) else {
                    throw NativeQobuzError.fileSystem("Bundled validator is not executable.")
                }
                let paths = NativePaths()
                guard !paths.applicationSupportRoot.path.hasPrefix(Bundle.main.bundleURL.path),
                      !paths.defaultDownloadRoot.path.hasPrefix(Bundle.main.bundleURL.path) else {
                    throw NativeQobuzError.fileSystem("Mutable data resolves inside the app bundle.")
                }
                print("portable-smoke: ok")
                exit(0)
            } catch {
                fputs("portable-smoke: failed\n", stderr)
                exit(2)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            NativeContentView()
                .environmentObject(viewModel)
                .frame(
                    minWidth: 820,
                    maxWidth: .infinity,
                    minHeight: 560,
                    maxHeight: .infinity
                )
                .task { viewModel.start() }
                .onOpenURL { viewModel.handleOpenURL($0) }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { viewModel.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandMenu("Queue") {
                Button("Download Selected") { viewModel.downloadSelected() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!viewModel.canDownloadSelected)
                Button("Download All") { viewModel.downloadAll() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!viewModel.canDownloadAll)
                Divider()
                Button("Cancel") { viewModel.cancelDownloads() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!viewModel.canCancel)
            }
        }
    }
}
