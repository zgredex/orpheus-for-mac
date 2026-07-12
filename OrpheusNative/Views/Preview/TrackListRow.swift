import SwiftUI

/// One track line in an album or playlist preview list.
struct TrackListRow: View {
    enum Leading {
        case number(Int?)
        case artist(String)
    }

    let leading: Leading
    let title: String
    let duration: Int?

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
            Spacer()
            Text(Format.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
