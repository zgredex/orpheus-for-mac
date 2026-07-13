import SwiftUI

/// One track line in an album or playlist preview list.
struct TrackListRow: View {
    enum Leading {
        case number(Int?)
        case artist(String)
    }

    let leading: Leading
    let title: String
    var isExplicit = false
    let duration: Int?
    var isQueued = false
    var libraryStatus: NativeLibraryStatus?
    var quality: QualityBadge.Kind?
    var unavailableReason: String?
    var add: (() -> Void)?

    var body: some View {
        HStack {
            switch leading {
            case .number(let number):
                Text("\(number ?? 0)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            case .artist(let name):
                Text(name)
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
            }
            Text(title).lineLimit(1)
            if isExplicit {
                Text("E")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
            if let unavailableReason {
                Label("Unavailable", systemImage: "nosign")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(unavailableReason)
            }
            Spacer()
            Text(Format.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let quality {
                QualityBadge(kind: quality)
            }
            if let libraryStatus {
                LibraryStatusLabel(status: libraryStatus, compact: true)
            }
            if add != nil, unavailableReason == nil {
                AddToQueueButton(isQueued: isQueued, add: add)
            }
        }
    }
}
