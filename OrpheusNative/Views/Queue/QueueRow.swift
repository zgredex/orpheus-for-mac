import NativeQobuzCore
import SwiftUI

struct QueueRow: View {
    let item: NativeQueueItem
    let targetQuality: QobuzQuality
    var libraryStatus: NativeLibraryStatus?

    var body: some View {
        HStack(spacing: 9) {
            ArtworkView(url: item.artworkURL, size: DS.Artwork.queue, placeholderSymbol: icon)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title).font(.rowTitle).lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    Text(item.subtitle).font(.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
                    if let libraryStatus {
                        LibraryStatusLabel(status: libraryStatus, compact: true)
                    }
                }
            }
            Spacer(minLength: DS.Space.xs)
            QualityBadge(kind: .target(targetQuality))
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
        if item.status == .paused { return "Paused. Resume to continue the existing partial download." }
        return nil
    }

    private var icon: String {
        switch item.request {
        case .album: "square.stack"
        case .artist: "person.crop.circle"
        case .playlist: "music.note.list"
        case .track: "music.note"
        case .label: "building.2"
        }
    }
}
