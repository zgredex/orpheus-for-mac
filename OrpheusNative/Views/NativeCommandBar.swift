import NativeQobuzCore
import SwiftUI

struct NativeCommandBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    @EnvironmentObject private var account: NativeAccountController
    @EnvironmentObject private var queue: NativeQueueController
    @EnvironmentObject private var downloads: NativeDownloadController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            commandRow(compact: false)
            commandRow(compact: true)
        }
    }

    private func commandRow(compact: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            downloadLocation
            Spacer(minLength: DS.Space.m)
            Button("Cancel", systemImage: "xmark.circle", action: vm.cancelDownloads)
                .labelStyle(NativeCommandLabelStyle(compact: compact))
                .disabled(!vm.canCancel)
                .help("Cancel active downloads")
            Button("Download Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: vm.downloadNext)
                .labelStyle(NativeCommandLabelStyle(compact: compact))
                .disabled(!vm.canDownloadNext)
                .help("Download only the first ready item in queue order")
            Button(selectedTitle, systemImage: selectedIcon, action: vm.downloadSelected)
                .labelStyle(NativeCommandLabelStyle(compact: compact))
                .disabled(!vm.canDownloadSelected)
                .help(selectedTitle)
            Button(compact ? "All" : "Download All", systemImage: "arrow.down.circle.fill", action: vm.downloadAll)
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canDownloadAll)
                .help("Download every ready queue item")
        }
    }

    private var downloadLocation: some View {
        Button(action: vm.revealDownloadRoot) {
            Label {
                Text(account.settings.downloadPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: 100,
            maxWidth: DS.Column.commandPathMaximum,
            alignment: .leading
        )
        .help(account.settings.downloadPath)
    }

    private var selectedTitle: String {
        selectedIsPaused ? "Resume Selected" : "Download Selected"
    }

    private var selectedIcon: String {
        selectedIsPaused ? "play.circle" : "arrow.down.circle"
    }

    private var selectedIsPaused: Bool {
        guard let item = queue.selectedItem else { return false }
        return downloads.status(for: item) == .paused
    }
}

private struct NativeCommandLabelStyle: LabelStyle {
    let compact: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            Label {
                configuration.title
            } icon: {
                configuration.icon
            }
        }
    }
}
