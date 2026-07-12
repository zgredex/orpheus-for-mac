import NativeQobuzCore
import SwiftUI

struct NativeCommandBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        HStack(spacing: 10) {
            Label(vm.settings.quality.displayName, systemImage: "waveform")
                .font(.caption.weight(.medium))
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Button(action: vm.revealDownloadRoot) {
                Text(vm.settings.downloadPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(vm.settings.downloadPath)
            Spacer()
            Button("Cancel", systemImage: "xmark.circle", action: vm.cancelDownloads).disabled(!vm.canCancel)
            Button("Download Selected", systemImage: "arrow.down.circle", action: vm.downloadSelected)
                .disabled(!vm.canDownloadSelected)
            Button("Download All", systemImage: "arrow.down.circle.fill", action: vm.downloadAll)
                .buttonStyle(.borderedProminent).disabled(!vm.canDownloadAll)
        }
    }
}
