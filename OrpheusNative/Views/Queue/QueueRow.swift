import NativeQobuzCore
import SwiftUI

struct QueueRow: View {
    let item: NativeQueueItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            statusSymbol
        }
        .frame(minHeight: 38)
    }

    private var icon: String {
        switch item.request {
        case .album: "square.stack"
        case .artist: "person.crop.circle"
        case .playlist: "music.note.list"
        case .track: "music.note"
        }
    }

    private var tint: Color {
        switch item.status {
        case .failed: .red
        case .completed: .green
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    @ViewBuilder private var statusSymbol: some View {
        switch item.status {
        case .loading: ProgressView().controlSize(.small)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .ready: EmptyView()
        }
    }
}
