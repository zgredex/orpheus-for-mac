import SwiftUI

struct ActivityRow: View {
    @EnvironmentObject private var vm: NativeViewModel
    let activity: NativeDownloadActivity

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(style: activity.status.style)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text(activity.title)
                        .font(.rowTitle)
                        .foregroundStyle(activity.status == .completed ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    // Kept in the layout and only faded so the row does not
                    // reflow; visible for the whole active download once the
                    // first speed sample arrives.
                    Label("\(Format.bytes(Int64(activity.bytesPerSecond ?? 0)))/s", systemImage: "arrow.down")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .opacity(activity.status.isActive && (activity.bytesPerSecond ?? 0) > 0 ? 1 : 0)
                }
                if activity.status != .completed {
                    ProgressView(value: activity.progress)
                        .tint(isFailed ? .red : .accentColor)
                        .animation(.linear(duration: 0.25), value: activity.progress)
                }
                HStack(spacing: 6) {
                    Text(phaseText)
                    if activity.totalTracks > 0 { Text("\(activity.completedTracks)/\(activity.totalTracks) tracks") }
                    if let written = activity.bytesWritten { Text(transfer(written, activity.totalBytes)) }
                    if activity.status == .completed, let checksum = activity.checksum {
                        Text("SHA-256 \(checksum.prefix(8))")
                    }
                }
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            if activity.outputURL != nil {
                Button { vm.reveal(activity) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .frame(minHeight: 54)
    }

    private var isFailed: Bool {
        if case .failed = activity.status { return true }
        return false
    }

    private var phaseText: String {
        if activity.status == .downloading, let current = activity.currentTrack {
            return "\(activity.phase) · \(current)"
        }
        return activity.phase
    }

    private func transfer(_ written: Int64, _ total: Int64?) -> String {
        guard let total else { return Format.bytes(written) }
        return "\(Format.bytes(written))/\(Format.bytes(total))"
    }
}
