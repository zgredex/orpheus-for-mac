import SwiftUI

struct InputBarView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)

                TextField("Paste link or search Qobuz", text: $vm.linkInput)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit(vm.addLinkInput)

                Button(action: vm.addLinkInput) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(vm.linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(vm.linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add link or search")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18))
            }

            Button(action: vm.toggleBatchInput) {
                Label("Paste Many", systemImage: "text.badge.plus")
            }
            .buttonStyle(.bordered)
            .help("Paste multiple links")
            .popover(isPresented: $vm.showBatchInput, arrowEdge: .bottom) {
                MultipleLinksPopover()
                    .environmentObject(vm)
            }

            Button(action: vm.importTextFile) {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            .help("Import text file")

            Picker("Quality", selection: $vm.selectedQuality) {
                Text("24-bit FLAC").tag("hifi")
                Text("16-bit FLAC").tag("lossless")
                Text("320 kbps MP3").tag("high")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 132)
            .onChange(of: vm.selectedQuality) { _, _ in
                vm.selectedQualityChanged()
            }
        }
        .controlSize(.regular)
    }
}

private struct MultipleLinksPopover: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Paste Multiple")
                    .font(.headline)
                Spacer()
                Button(action: vm.toggleBatchInput) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.batchInput)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)

                if vm.batchInput.isEmpty {
                    Text("Paste Qobuz links")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 430, height: 210)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18))
            }

            HStack {
                Button(action: addAndClose) {
                    Label("Add Links", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.batchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: vm.clearInput) {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(vm.batchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
        }
        .padding(14)
    }

    private func addAndClose() {
        vm.addLinksFromInput()
        vm.showBatchInput = false
    }
}

struct QueuePaneView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                CountBadge(value: vm.queuedLinks.count)
                Spacer()
                Button(action: vm.clearQueue) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(vm.queuedLinks.isEmpty)
                .help("Clear queue")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let notice = vm.queueNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Divider()

            if vm.queuedLinks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Queue is empty")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $vm.selectedQueueID) {
                    ForEach(vm.queuedLinks) { item in
                        QueueRowView(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: vm.selectedQueueID) { _, _ in
                    vm.selectedQueueItemChanged()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CountBadge: View {
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

private struct QueueRowView: View {
    let item: QueuedLink
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 10) {
            QueueArtworkView(item: item, tint: stateColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(item.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.state != .ready {
                QueueStateBadge(label: item.state.label, color: stateColor)
            }

            Button(action: { vm.removeQueueItem(id: item.id) }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Download") {
                vm.selectedQueueID = item.id
                vm.downloadSelected()
            }
            .disabled(!item.state.canStart)

            Button("Remove") {
                vm.removeQueueItem(id: item.id)
            }
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .ready:
            return .secondary
        case .loadingMetadata, .queued:
            return .blue
        case .downloading:
            return .accentColor
        case .completed:
            return .green
        case .metadataFailed:
            return .orange
        case .invalid, .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }
}

private struct QueueStateBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

private struct QueueArtworkView: View {
    let item: QueuedLink
    let tint: Color

    var body: some View {
        ZStack {
            if let coverURL = item.coverURL,
               !coverURL.isEmpty,
               let url = URL(string: coverURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(0.12))
            .overlay {
                Image(systemName: item.parsed.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
    }
}
