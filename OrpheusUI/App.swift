import SwiftUI

@main
struct OrpheusUIApp: App {
    @StateObject private var viewModel = MainViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    viewModel.openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Focus Search") {
                    viewModel.focusSearch()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Paste Multiple Links") {
                    viewModel.showMultipleLinks()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            CommandMenu("Queue") {
                Button("Download Selected") {
                    viewModel.downloadSelected()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.canDownloadSelected)

                Button("Download All") {
                    viewModel.downloadAllQueued()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!viewModel.canDownloadAll)

                Divider()

                Button("Cancel Download") {
                    viewModel.cancelAllDownloads()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!viewModel.canCancelDownloads)

                Button("Clear Finished Downloads") {
                    viewModel.clearDownloads()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!viewModel.canClearFinishedDownloads)
            }
        }
    }
}
