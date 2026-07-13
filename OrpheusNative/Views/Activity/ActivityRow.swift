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
                    if !activity.warnings.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .help(activity.warnings.joined(separator: "\n"))
                    }
                    if let quality = activity.quality {
                        QualityBadge(kind: .target(quality))
                    }
                    // Kept in the layout and only faded so the row does not
                    // reflow; visible for the whole active download once the
                    // first speed sample arrives.
                    Label("\(Format.bytes(Int64(activity.bytesPerSecond ?? 0)))/s", systemImage: "arrow.down")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .opacity(activity.status == .downloading && (activity.bytesPerSecond ?? 0) > 0 ? 1 : 0)
                }
                if activity.status != .completed {
                    ProgressView(value: activity.progress)
                        .tint(isFailed ? .red : .accentColor)
                        .animation(.linear(duration: 0.25), value: activity.progress)
                }
                HStack(spacing: 6) {
                    Text(phaseText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.s)
                    // Trailing numeric group: right-aligned with a reserved
                    // width so changing digits never push the line around.
                    if activity.totalTracks > 0 {
                        Text("\(activity.completedTracks)/\(activity.totalTracks) tracks")
                    }
                    if let size = activity.albumBytesWritten ?? activity.bytesWritten {
                        Text(Format.bytes(size))
                            .frame(minWidth: 90, alignment: .trailing)
                    }
                }
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            if activity.status == .paused {
                Button("Resume", systemImage: "play.fill") { vm.resume(activity) }
                    .controlSize(.small)
                    .disabled(vm.isDownloading)
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
}
