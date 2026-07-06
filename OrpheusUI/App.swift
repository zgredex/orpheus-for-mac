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
            CommandGroup(after: .pasteboard) {
                Button("Download") {
                    viewModel.downloadSelected()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
