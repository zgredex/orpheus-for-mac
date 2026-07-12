import NativeQobuzCore
import SwiftUI

struct QueueRow: View {
    let item: NativeQueueItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title).font(.rowTitle).lineLimit(1)
                Text(item.subtitle).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.xs)
            if let style = item.status.style {
                StatusGlyph(style: style)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(minHeight: 38)
        .animation(.default, value: item.status)
        .help(failureMessage ?? "")
    }

    private var failureMessage: String? {
        if case .failed(let message) = item.status { return message }
        return nil
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
        item.status.style?.tint ?? .accentColor
    }
}
