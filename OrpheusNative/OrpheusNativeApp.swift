import SwiftUI

@main
struct OrpheusNativeApp: App {
    @StateObject private var viewModel = NativeViewModel()

    var body: some Scene {
        WindowGroup {
            NativeContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 820, minHeight: 560)
                .task { viewModel.start() }
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
