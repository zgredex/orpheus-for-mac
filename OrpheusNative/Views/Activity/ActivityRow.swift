import SwiftUI

struct ActivityRow: View {
    @EnvironmentObject private var vm: NativeViewModel
    let activity: NativeDownloadActivity
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.m) {
                StatusGlyph(style: activity.status.activityStyle)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.s) {
                        Text(activity.title)
                            .font(.rowTitle)
                            .foregroundStyle(activity.status == .completed ? .secondary : .primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if hasDetails {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { showsDetails.toggle() }
                            } label: {
                                HStack(spacing: DS.Space.xxs) {
                                    Image(systemName: detailIcon)
                                    Text(detailSummary)
                                    Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(detailTint)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.plain)
                            .help(showsDetails ? "Hide details" : "Show delivery, error, and warning details")
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
                    if let partial = vm.resumablePartial(for: activity) {
                        Label(
                            "\(Format.bytes(partial.bytes)) partial file will be resumed",
                            systemImage: "arrow.clockwise.circle.fill"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    if let quality = activity.quality {
                        QualityBadge(kind: .target(quality))
                    } else if let format = activity.audioFormat {
                        QualityBadge(kind: .exact(format))
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

                actionButtons
                    .frame(width: DS.Column.activityActions, alignment: .trailing)
            }
            .frame(minHeight: 58)

            if showsDetails, hasDetails {
                detailContent
                    .padding(.leading, 20 + DS.Space.m)
                    .padding(.top, DS.Space.s)
                    .padding(.bottom, DS.Space.xs)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.default, value: activity.status)
    }

    private var actionButtons: some View {
        HStack(spacing: DS.Space.s) {
            if activity.status.isActive {
                Button("Cancel", systemImage: "xmark.circle") { vm.cancel(activity) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!vm.canCancel(activity))
                    .help("Cancel this item and continue the remaining batch")
            } else if activity.status.canRetry {
                Button("Retry", systemImage: "arrow.clockwise") { vm.retry(activity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.canRestart(activity))
                    .help(restartHelp(action: "Retry"))
            } else if activity.status.canResume {
                Button("Resume", systemImage: "play.fill") { vm.resume(activity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.canRestart(activity))
                    .help(restartHelp(action: "Resume"))
            }

            Button("Reveal", systemImage: "folder") { vm.reveal(activity) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(vm.resumablePartial(for: activity) == nil
                    ? "Show the download location in Finder"
                    : "Show the resumable partial file in Finder")

            Button("Remove", systemImage: "trash") { vm.removeActivity(activity) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(activity.status.isActive)
                .help("Remove from Activity without deleting downloaded or partial files")
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let error = activity.detailError {
                detailSection(
                    title: "Error",
                    systemImage: "exclamationmark.circle.fill",
                    tint: .red,
                    messages: [error]
                )
            }
            if !activity.warnings.isEmpty {
                detailSection(
                    title: activity.warnings.count == 1 ? "Warning" : "Warnings",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    messages: activity.warnings
                )
            }
            if !activity.informationalNotices.isEmpty {
                detailSection(
                    title: activity.informationalNotices.count == 1 ? "Delivery detail" : "Delivery details",
                    systemImage: "info.circle.fill",
                    tint: .blue,
                    messages: activity.informationalNotices
                )
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func detailSection(
        title: String,
        systemImage: String,
        tint: Color,
        messages: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(messages.indices, id: \.self) { index in
                Text(messages[index])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = activity.status { return true }
        return false
    }

    private var hasDetails: Bool {
        activity.detailError != nil
            || !activity.warnings.isEmpty
            || !activity.informationalNotices.isEmpty
    }

    private var detailIcon: String {
        if activity.detailError != nil { return "exclamationmark.circle.fill" }
        if !activity.warnings.isEmpty { return "exclamationmark.triangle.fill" }
        return "info.circle.fill"
    }

    private var detailTint: Color {
        if activity.detailError != nil { return .red }
        if !activity.warnings.isEmpty { return .orange }
        return .blue
    }

    private var detailSummary: String {
        var values: [String] = []
        if activity.detailError != nil { values.append("Error") }
        if !activity.warnings.isEmpty {
            values.append("\(activity.warnings.count) warning\(activity.warnings.count == 1 ? "" : "s")")
        }
        if !activity.informationalNotices.isEmpty {
            values.append("\(activity.informationalNotices.count) detail\(activity.informationalNotices.count == 1 ? "" : "s")")
        }
        return values.joined(separator: " · ")
    }

    private var phaseText: String {
        if isFailed { return "Failed · Expand for details" }
        if activity.status == .waitingForNetwork { return activity.phase }
        if activity.status == .paused, activity.detailError != nil { return "Paused · Ready to resume" }
        if activity.status == .downloading, let current = activity.currentTrack {
            return "\(activity.phase) · \(current)"
        }
        return activity.phase
    }

    private func restartHelp(action: String) -> String {
        guard vm.canRestart(activity) else {
            return vm.isDownloading
                ? "Wait for the current download to finish"
                : "The original queue item is no longer available"
        }
        if vm.resumablePartial(for: activity) != nil {
            return "\(action) and resume the existing partial file"
        }
        return "\(action) this download"
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
