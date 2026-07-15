import NativeQobuzCore
import SwiftUI

struct NativeCommandBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        HStack(spacing: 10) {
            Button(action: vm.revealDownloadRoot) {
                Text(vm.settings.downloadPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(vm.settings.downloadPath)
            Spacer()
            Button("Cancel", systemImage: "xmark.circle", action: vm.cancelDownloads).disabled(!vm.canCancel)
            Button("Download Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: vm.downloadNext)
                .disabled(!vm.canDownloadNext)
                .help("Download only the first ready item in queue order")
            Button(selectedTitle, systemImage: selectedIcon, action: vm.downloadSelected)
                .disabled(!vm.canDownloadSelected)
            Button("Download All", systemImage: "arrow.down.circle.fill", action: vm.downloadAll)
                .buttonStyle(.borderedProminent).disabled(!vm.canDownloadAll)
        }
    }

    private var selectedTitle: String {
        selectedIsPaused ? "Resume Selected" : "Download Selected"
    }

    private var selectedIcon: String {
        selectedIsPaused ? "play.circle" : "arrow.down.circle"
    }

    private var selectedIsPaused: Bool {
        guard let item = vm.selectedQueueItem else { return false }
        return vm.status(for: item) == .paused
    }
}
