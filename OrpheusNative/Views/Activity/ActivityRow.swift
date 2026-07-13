import SwiftUI

struct ActivityRow: View {
    @EnvironmentObject private var vm: NativeViewModel
    let activity: NativeDownloadActivity

    var body: some View {
        HStack(spacing: DS.Space.m) {
            StatusGlyph(style: activity.status.style)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Text(activity.title)
                        .font(.rowTitle)
                        .foregroundStyle(activity.status == .completed ? .secondary : .primary)
                        .lineLimit(1)
                    if !activity.warnings.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .help(activity.warnings.joined(separator: "\n"))
                    }
                    Spacer(minLength: 0)
                }
                if activity.status != .completed {
                    ProgressView(value: activity.progress)
                        .tint(isFailed ? .red : .accentColor)
                        .animation(.linear(duration: 0.25), value: activity.progress)
                }
                Text(phaseText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                if let quality = activity.quality {
                    QualityBadge(kind: .target(quality))
                } else {
                    Color.clear.frame(height: 18)
                }
                if activity.totalTracks > 0 {
                    Text("\(activity.completedTracks)/\(activity.totalTracks) tracks")
                        .monospacedDigit()
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: DS.Column.activityQuality, alignment: .trailing)

            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                Text(transferPrimaryText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(transferSecondaryText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: DS.Column.activityTransfer, alignment: .trailing)

            HStack(spacing: DS.Space.s) {
                if activity.status == .paused {
                    Button { vm.resume(activity) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .disabled(vm.isDownloading)
                        .help("Resume download")
                }
                if activity.outputURL != nil {
                    Button { vm.reveal(activity) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
            }
            .frame(width: DS.Column.activityActions, alignment: .trailing)
        }
        .frame(minHeight: 58)
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

    private var transferredBytes: Int64? {
        activity.albumBytesWritten ?? activity.bytesWritten
    }

    private var hasLiveSpeed: Bool {
        activity.status == .downloading && (activity.bytesPerSecond ?? 0) > 0
    }

    private var transferPrimaryText: String {
        if hasLiveSpeed {
            return "\(Format.bytes(Int64(activity.bytesPerSecond ?? 0)))/s"
        }
        if let transferredBytes {
            return Format.bytes(transferredBytes)
        }
        return "—"
    }

    private var transferSecondaryText: String {
        if hasLiveSpeed, let transferredBytes {
            return "\(Format.bytes(transferredBytes)) transferred"
        }
        if transferredBytes != nil {
            return activity.status == .completed ? "Downloaded" : "Transferred"
        }
        return " "
    }
}
