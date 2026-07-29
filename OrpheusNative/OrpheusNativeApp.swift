import Darwin
import NativeQobuzCore
import SwiftUI

@main
struct OrpheusNativeApp: App {
    @StateObject private var viewModel: NativeViewModel

    init() {
        NSSetUncaughtExceptionHandler { exception in
            qobuzLog.critical(
                "crash.exception",
                "Uncaught Objective-C exception",
                metadata: [
                    "exceptionName": exception.name.rawValue,
                    "reason": exception.reason ?? "unknown",
                    "callStack": exception.callStackSymbols.joined(separator: " | ")
                ]
            )
        }
        let paths = NativeProcessContext.paths
        _viewModel = StateObject(wrappedValue: NativeViewModel(paths: paths))
        qobuzLog.notice(
            "lifecycle",
            "App process initialized",
            metadata: [
                "processID": String(ProcessInfo.processInfo.processIdentifier),
                "arguments": ProcessInfo.processInfo.arguments.map {
                    QobuzDiagnostics.redact($0)
                }.joined(separator: " ")
            ]
        )
        if ProcessInfo.processInfo.arguments.contains("--portability-smoke-test") {
            qobuzLog.notice("qualification", "Portability smoke test started")
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
                qobuzLog.notice("qualification", "Portability smoke test passed")
                print("portable-smoke: ok")
                exit(0)
            } catch {
                qobuzLog.critical("qualification", "Portability smoke test failed", error: error)
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
                    minWidth: DS.Window.minimumWidth,
                    maxWidth: .infinity,
                    minHeight: DS.Window.minimumHeight,
                    maxHeight: .infinity
                )
                .task {
                    if !NativeProcessContext.isRunningUnitTests { viewModel.start() }
                }
                .onOpenURL {
                    qobuzLog.info(
                        "lifecycle.url",
                        "App received an open-URL event",
                        metadata: ["scheme": $0.scheme ?? "none", "host": $0.host ?? "none"]
                    )
                    viewModel.handleOpenURL($0)
                }
        }
        .defaultSize(width: DS.Window.defaultWidth, height: DS.Window.defaultHeight)
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
            CommandMenu("Diagnostics") {
                Button("Open Diagnostics") { viewModel.showDiagnostics = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Reveal Log Files") { viewModel.diagnostics.reveal() }
            }
        }
    }
}
