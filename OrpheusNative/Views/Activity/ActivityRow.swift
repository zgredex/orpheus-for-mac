import SwiftUI

struct ActivityRow: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let activity: NativeDownloadActivity
    let status: NativeDownloadStatus
    @Binding var showsDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    compactRow
                } else {
                    ViewThatFits(in: .horizontal) {
                        regularRow
                            .frame(minWidth: DS.Row.activityRegularMinimumWidth)
                        compactRow
                    }
                }
            }

            if showsDetails, hasDetails {
                ActivityDetailView(
                    error: detailError,
                    warnings: activity.warnings,
                    notices: activity.informationalNotices
                )
                    .padding(.leading, 20 + DS.Space.m)
                    .padding(.top, DS.Space.s)
                    .padding(.bottom, DS.Space.xs)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.default, value: status)
    }

    private var regularRow: some View {
        HStack(spacing: DS.Space.m) {
            statusGlyph
            primaryContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minWidth: DS.Row.activityPrimaryMinimumWidth)
                .layoutPriority(1)
            qualityContent
                .frame(width: DS.Column.activityQuality, alignment: .trailing)
            transferContent
                .frame(width: DS.Column.activityTransfer, alignment: .trailing)
            actionButtons
                .frame(width: DS.Column.activityActions, alignment: .trailing)
        }
        .frame(minHeight: 58)
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                statusGlyph
                primaryContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                actionButtons
            }
            HStack(alignment: .bottom, spacing: DS.Space.m) {
                compactQualityContent
                Spacer(minLength: DS.Space.m)
                compactTransferContent
            }
            .padding(.leading, 20 + DS.Space.m)
        }
        .padding(.vertical, DS.Space.xs)
    }

    private var statusGlyph: some View {
        StatusGlyph(style: status.activityStyle)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 20)
    }

    private var primaryContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            titleAndDetails
            if status != .completed {
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
                .lineLimit(1)
            }
        }
    }

    private var titleAndDetails: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s) {
                title
                detailButton
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                title
                detailButton
            }
        }
    }

    private var title: some View {
        Text(activity.title)
            .font(.rowTitle)
            .foregroundStyle(status == .completed ? .secondary : .primary)
            .lineLimit(1)
            .layoutPriority(1)
    }

    @ViewBuilder private var detailButton: some View {
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
    }

    private var qualityContent: some View {
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
    }

    private var compactQualityContent: some View {
        HStack(spacing: DS.Space.s) {
            if let quality = activity.quality {
                QualityBadge(kind: .target(quality))
            } else if let format = activity.audioFormat {
                QualityBadge(kind: .exact(format))
            }
            if activity.totalTracks > 0 {
                Text("\(activity.completedTracks)/\(activity.totalTracks) tracks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var transferContent: some View {
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
    }

    private var compactTransferContent: some View {
        Text("\(transferPrimaryText) · \(transferSecondaryText)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .monospacedDigit()
    }

    private var actionButtons: some View {
        HStack(spacing: DS.Space.s) {
            if status.isActive {
                Button("Cancel", systemImage: "xmark.circle") { vm.cancel(activity) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!vm.canCancel(activity))
                    .help("Cancel this item and continue the remaining batch")
            } else if status.canRetry {
                Button("Retry", systemImage: "arrow.clockwise") { vm.retry(activity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.canRestart(activity))
                    .help(restartHelp(action: "Retry"))
            } else if status.canResume {
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
                .disabled(status.isActive)
                .help("Remove from Activity without deleting downloaded or partial files")
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var hasDetails: Bool {
        detailError != nil
            || !activity.warnings.isEmpty
            || !activity.informationalNotices.isEmpty
    }

    private var detailIcon: String {
        if detailError != nil { return "exclamationmark.circle.fill" }
        if !activity.warnings.isEmpty { return "exclamationmark.triangle.fill" }
        return "info.circle.fill"
    }

    private var detailTint: Color {
        if detailError != nil { return .red }
        if !activity.warnings.isEmpty { return .orange }
        return .blue
    }

    private var detailSummary: String {
        var values: [String] = []
        if detailError != nil { values.append("Error") }
        if !activity.warnings.isEmpty {
            values.append("\(activity.warnings.count) warning\(activity.warnings.count == 1 ? "" : "s")")
        }
        if !activity.informationalNotices.isEmpty {
            values.append("\(activity.informationalNotices.count) detail\(activity.informationalNotices.count == 1 ? "" : "s")")
        }
        return values.joined(separator: " · ")
    }

    private var phaseText: String {
        if isFailed {
            return showsDetails ? activity.phase : "Failed · Expand for details"
        }
        if status == .waitingForNetwork { return activity.phase }
        if status == .paused, detailError != nil { return "Paused · Ready to resume" }
        if status == .downloading, let current = activity.currentTrack {
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
        status == .downloading && (activity.bytesPerSecond ?? 0) > 0
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
            return status == .completed ? "Downloaded" : "Transferred"
        }
        return " "
    }

    private var detailError: String? {
        vm.detailError(for: activity)
    }
}
