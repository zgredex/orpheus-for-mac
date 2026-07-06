import SwiftUI

struct DownloadsSectionView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Activity", systemImage: "arrow.down.circle")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                DownloadCountBadge(value: vm.downloads.count)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if vm.downloads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No downloads")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.downloads.enumerated()), id: \.element.id) { index, item in
                            DownloadRowView(item: item)
                            if index < vm.downloads.index(before: vm.downloads.endIndex) {
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DownloadCountBadge: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

struct DownloadRowView: View {
    let item: DownloadItem
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)

                statusDetails
            }

            Spacer(minLength: 10)

            if let speed = item.speedBadgeLabel {
                SpeedBadge(speed: speed)
            }

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var statusDetails: some View {
        switch item.status {
        case .queued:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView(value: item.progress)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Text(item.unitProgressLabel ?? "\(Int(item.progress * 100))%")
                if let downloaded = item.downloaded, let total = item.total {
                    Text("\(downloaded)/\(total)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .completed:
            Text("Done")
                .font(.caption)
                .foregroundStyle(.green)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .queued:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .scaleEffect(0.65)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.status {
        case .queued, .downloading:
            Button(action: { vm.cancelDownload(id: item.id) }) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Cancel")
        case .completed:
            Button(action: { vm.revealInFinder(id: item.id) }) {
                Image(systemName: "finder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
        case .failed, .cancelled:
            Button(action: { vm.removeDownload(id: item.id) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
    }
}

private struct SpeedBadge: View {
    let speed: String

    var body: some View {
        Label(speed, systemImage: "arrow.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help("Download speed")
    }
}
