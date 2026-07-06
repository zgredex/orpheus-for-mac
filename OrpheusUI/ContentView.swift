import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            InputBarView()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            HSplitView {
                QueuePaneView()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 430)

                DetailPaneView()
                    .frame(minWidth: 500, idealWidth: 680)
            }

            Divider()

            BottomCommandBarView()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { vm.loadSettings() }
        .toolbar {
            ToolbarItemGroup {
                Button(action: vm.openSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsView()
                .environmentObject(vm)
        }
    }
}

private struct DetailPaneView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            DownloadsSectionView()
                .frame(minHeight: 170, idealHeight: 210, maxHeight: 260)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if vm.isBrowseActive {
            SearchContentView()
        } else {
            switch vm.previewState {
            case .idle:
                EmptyPreviewView()
            case .loading:
                ProgressView("Loading Qobuz metadata...")
            case .loadedAlbum(let info):
                AlbumPreviewView(info: info)
            case .loadedTrack(let info):
                TrackPreviewView(info: info)
            case .loadedArtist(let info):
                ArtistPreviewView(info: info)
            case .loadedCollection(let info):
                CollectionPreviewView(info: info)
            case .regionMismatch(let yourRegion, let blockedRegion):
                RegionMismatchView(yourRegion: yourRegion, blockedRegion: blockedRegion)
            case .error(let message):
                if vm.settingsLoadFailed {
                    ErrorPreviewView(message: message, retryAction: { vm.loadSettings() })
                } else {
                    ErrorPreviewView(message: message, retryAction: nil)
                }
            }
        }
    }
}

private struct BottomCommandBarView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.queueStatusSummary)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(vm.downloadStatusSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 220, alignment: .leading)

            Spacer(minLength: 12)

            Button(action: vm.cancelAllDownloads) {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(!vm.canCancelDownloads)
            .help("Cancel active download")

            Button(action: vm.clearDownloads) {
                Label("Clear Finished", systemImage: "trash")
            }
            .disabled(!vm.canClearFinishedDownloads)
            .help("Clear finished downloads")

            Divider()
                .frame(height: 22)

            Button(action: vm.downloadSelected) {
                Label(vm.selectedDownloadActionTitle, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canDownloadSelected)
            .help("Download selected queue item")

            Button(action: vm.downloadAllQueued) {
                Label("Download All", systemImage: "arrow.down.circle.fill")
            }
            .disabled(!vm.canDownloadAll)
            .help("Download all ready queue items")
        }
        .controlSize(.regular)
    }
}

private struct EmptyPreviewView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("No queue item selected")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ErrorPreviewView: View {
    let message: String
    let retryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let retryAction {
                Button(action: retryAction) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
