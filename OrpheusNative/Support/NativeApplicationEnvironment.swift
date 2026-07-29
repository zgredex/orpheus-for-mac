import SwiftUI

extension View {
    @MainActor
    func nativeApplicationEnvironment(_ viewModel: NativeViewModel) -> some View {
        environmentObject(viewModel)
            .environmentObject(viewModel.account)
            .environmentObject(viewModel.browse)
            .environmentObject(viewModel.queueController)
            .environmentObject(viewModel.previewController)
            .environmentObject(viewModel.linkInboxController)
            .environmentObject(viewModel.library)
            .environmentObject(viewModel.libraryManagement)
            .environmentObject(viewModel.connectivity)
            .environmentObject(viewModel.downloads)
    }
}
