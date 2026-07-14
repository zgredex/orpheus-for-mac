import NativeQobuzCore
import SwiftUI

struct QueueRow: View {
    @EnvironmentObject private var vm: NativeViewModel

    let item: NativeQueueItem
    let targetQuality: QobuzQuality
    var libraryStatus: NativeLibraryStatus?
    var isExpanded = false
    var toggleExpanded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.vertical, DS.Space.xs)

            if isExpanded {
                Divider()
                    .padding(.vertical, DS.Space.xs)
                inspector
                    .padding(.bottom, DS.Space.s)
            }
        }
        .animation(.default, value: item.status)
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
        .help(failureMessage ?? "Drag to reorder. Expand to inspect this download plan.")
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse download plan" : "Inspect download plan")

            ArtworkView(url: item.artworkURL, size: DS.Artwork.queue, placeholderSymbol: icon)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title).font(.rowTitle).lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    Text(headerSubtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let libraryStatus {
                        LibraryStatusLabel(status: libraryStatus, compact: true)
                    }
                }
            }
            Spacer(minLength: DS.Space.xs)
            if let format = item.repairTarget?.audioFormat {
                QualityBadge(kind: .exact(format))
            } else {
                QualityBadge(kind: .target(targetQuality))
            }
            if let style = item.status.style {
                StatusGlyph(style: style)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(minHeight: 38)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            preflightGrid

            HStack(spacing: DS.Space.s) {
                Text("Quality")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                qualityMenu
            }

            if let trackPlan = item.trackPlan {
                HStack(spacing: DS.Space.s) {
                    Text("Tracks")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button("All") { vm.selectAllQueueTracks(in: item.id) }
                        .buttonStyle(.borderless)
                        .disabled(vm.isDownloading || item.selectedTrackIDs == nil)
                    Button("None") { vm.clearQueueTrackSelection(in: item.id) }
                        .buttonStyle(.borderless)
                        .disabled(vm.isDownloading || item.effectiveSelectedTrackIDs.isEmpty)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(trackPlan) { track in
                            plannedTrackRow(track)
                            if track.id != trackPlan.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(trackPlan.count) * 36, 216))
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            } else {
                Label(planPlaceholder, systemImage: "list.bullet.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preflightGrid: some View {
        let preflight = vm.queuePreflight(for: item)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: DS.Space.xs)], spacing: DS.Space.xs) {
            QueueMetric(title: "Selected", value: preflight.selected.map(String.init) ?? "—")
            QueueMetric(title: "To download", value: preflight.needsDownload.map(String.init) ?? "—")
            QueueMetric(title: "In Library", value: String(preflight.verified), tint: .green)
            if preflight.unavailable > 0 {
                QueueMetric(title: "Unavailable", value: String(preflight.unavailable), tint: .orange)
            }
            if preflight.problems > 0 {
                QueueMetric(title: "Problems", value: String(preflight.problems), tint: .orange)
            }
        }
    }

    private var qualityMenu: some View {
        Menu {
            Button {
                vm.setQueueQuality(nil, for: item.id)
            } label: {
                Label(
                    "Default · \(vm.settings.quality.displayName)",
                    systemImage: item.downloadQuality == nil ? "checkmark" : "arrow.uturn.backward"
                )
            }
            Divider()
            ForEach(QobuzQuality.allCases, id: \.self) { quality in
                Button {
                    vm.setQueueQuality(quality, for: item.id)
                } label: {
                    Label(
                        quality.displayName,
                        systemImage: item.downloadQuality == quality ? "checkmark" : "waveform"
                    )
                }
            }
        } label: {
            Label(
                item.repairTarget?.audioFormat?.displayName
                    ?? (item.downloadQuality == nil
                        ? "Default · \(targetQuality.displayName)"
                        : targetQuality.displayName),
                systemImage: "waveform"
            )
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(vm.isDownloading || item.repairTarget != nil)
        .help(item.repairTarget == nil
            ? "Override the default quality for this queue item"
            : "Repairs use the quality recorded in the Library archive")
    }

    private func plannedTrackRow(_ track: NativeQueueTrack) -> some View {
        let selected = item.effectiveSelectedTrackIDs.contains(track.qobuzID)
        return HStack(spacing: DS.Space.xs) {
            Button {
                vm.toggleQueueTrack(track.qobuzID, in: item.id)
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(vm.isDownloading || !track.isAvailable)
            .help(track.unavailableReason ?? (selected ? "Exclude this track" : "Include this track"))

            Text("\(track.position)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.caption)
                    .foregroundStyle(track.isAvailable ? .primary : .secondary)
                    .lineLimit(1)
                Text(track.unavailableReason ?? track.subtitle)
                    .font(.caption2)
                    .foregroundStyle(track.isAvailable ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.xs)
            Text(Format.duration(track.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.xs)
        .frame(height: 35)
        .contentShape(Rectangle())
    }

    private var headerSubtitle: String {
        guard let plan = item.trackPlan else { return item.subtitle }
        let selected = plan.count { $0.isAvailable && item.effectiveSelectedTrackIDs.contains($0.qobuzID) }
        return "\(item.subtitle) · \(selected)/\(plan.filter(\.isAvailable).count) selected"
    }

    private var planPlaceholder: String {
        switch item.request {
        case .album, .playlist, .track:
            "The track plan appears after Qobuz metadata finishes loading."
        case .artist, .label:
            "Track selection is available after adding a specific album or track."
        }
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

private struct QueueMetric: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.xs)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.thumb))
    }
}
