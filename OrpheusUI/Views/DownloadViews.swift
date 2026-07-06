import SwiftUI

struct DownloadsSectionView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Text("\(vm.downloads.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)

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
                    LazyVStack(spacing: 1) {
                        ForEach(vm.downloads) { item in
                            DownloadRowView(item: item)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
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

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
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
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                Text(item.unitProgressLabel ?? "\(Int(item.progress * 100))%")
                if let speed = item.speed { Text(speed) }
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
            .help("Cancel")
        case .completed:
            Button(action: { vm.revealInFinder(id: item.id) }) {
                Image(systemName: "finder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        case .failed, .cancelled:
            Button(action: { vm.removeDownload(id: item.id) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }
}
