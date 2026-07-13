import NativeQobuzCore
import SwiftUI

struct LinkInboxSection: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(.secondary)
                Text("Link Inbox")
                    .font(.headline)
                Text("\(vm.linkInbox.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: vm.clearReviewedLinks) { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.plain)
                    .disabled(!vm.linkInbox.contains { $0.status.isReviewed })
                    .help("Clear reviewed links")
                Button(action: vm.clearLinkInbox) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .help("Clear link inbox")
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 38)

            List(vm.linkInbox) { item in
                inboxRow(item)
                    .contextMenu {
                        Button("Open", systemImage: "arrow.right") { vm.openInboxItem(item.id) }
                        if case .failed = item.status {
                            Button("Retry", systemImage: "arrow.clockwise") { vm.retryInboxItem(item.id) }
                        }
                        Divider()
                        Button("Remove", systemImage: "trash") { vm.removeInboxItem(item.id) }
                    }
            }
            .listStyle(.inset)
            .frame(height: min(CGFloat(vm.linkInbox.count) * 54 + 8, 220))
        }
    }

    private func inboxRow(_ item: NativeLinkInboxItem) -> some View {
        Button { vm.openInboxItem(item.id) } label: {
            HStack(spacing: 9) {
                ArtworkView(url: item.artworkURL, size: DS.Artwork.queue, placeholderSymbol: icon(for: item.request))
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(item.title).font(.rowTitle).foregroundStyle(.primary).lineLimit(1)
                    Text(item.status.message ?? item.subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(statusColor(item.status))
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.xs)
                statusView(item.status)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.status.message ?? "Open verified Qobuz detail")
    }

    @ViewBuilder private func statusView(_ status: NativeLinkReviewStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "nosign").foregroundStyle(.red)
        case .failed:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
        }
    }

    private func statusColor(_ status: NativeLinkReviewStatus) -> Color {
        switch status {
        case .available: .secondary
        case .partial: .orange
        case .unavailable, .failed: .red
        case .pending, .checking: .secondary
        }
    }

    private func icon(for request: QobuzRequest) -> String {
        switch request {
        case .album: "square.stack"
        case .artist: "person.crop.circle"
        case .playlist: "music.note.list"
        case .track: "music.note"
        case .label: "building.2"
        }
    }
}
