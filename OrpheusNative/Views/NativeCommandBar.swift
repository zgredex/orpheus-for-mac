import NativeQobuzCore
import SwiftUI

struct NativeCommandBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        HStack(spacing: 10) {
            Text(vm.settings.quality == .hiRes ? "Hi-Res FLAC" : vm.settings.quality == .lossless ? "Lossless FLAC" : "MP3 320 kbps")
                .font(.caption.weight(.medium))
            Text(vm.settings.downloadPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Cancel", systemImage: "xmark.circle", action: vm.cancelDownloads).disabled(!vm.canCancel)
            Button("Download Selected", systemImage: "arrow.down.circle", action: vm.downloadSelected)
                .disabled(!vm.canDownloadSelected)
            Button("Download All", systemImage: "arrow.down.circle.fill", action: vm.downloadAll)
                .buttonStyle(.borderedProminent).disabled(!vm.canDownloadAll)
        }
    }
}
