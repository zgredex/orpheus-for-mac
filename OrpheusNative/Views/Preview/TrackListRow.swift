import SwiftUI

/// One track line in an album or playlist preview list.
struct TrackListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    var isSelected: Bool?
    var toggleSelection: (() -> Void)?
    var add: (() -> Void)?

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                compactRow
            } else {
                ViewThatFits(in: .horizontal) {
                    regularRow
                        .frame(minWidth: DS.Row.trackRegularMinimumWidth)
                    compactRow
                }
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private var regularRow: some View {
        HStack(spacing: DS.Space.s) {
            selectionControl
            regularLeading
            titleLabel
                .layoutPriority(1)
            explicitBadge
            unavailableLabel
            Spacer(minLength: DS.Space.s)
            durationLabel
            qualityBadge
            libraryLabel
            addButton
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                selectionControl
                compactNumber
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    titleLabel
                    compactArtist
                }
                .layoutPriority(1)
                explicitBadge
                Spacer(minLength: DS.Space.xs)
                durationLabel
            }

            if hasSecondaryMetadata {
                HStack(spacing: DS.Space.s) {
                    unavailableLabel
                    Spacer(minLength: 0)
                    qualityBadge
                    libraryLabel
                    addButton
                }
            }
        }
    }

    @ViewBuilder private var selectionControl: some View {
        if let isSelected, let toggleSelection {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(unavailableReason != nil)
            .help(unavailableReason == nil
                ? (isSelected ? "Exclude this track" : "Include this track")
                : "This track is unavailable")
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
        }
    }

    @ViewBuilder private var regularLeading: some View {
        switch leading {
        case .number(let number):
            trackNumber(number)
        case .artist(let name):
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
    }

    @ViewBuilder private var compactNumber: some View {
        if case .number(let number) = leading {
            trackNumber(number)
        }
    }

    @ViewBuilder private var compactArtist: some View {
        if case .artist(let name) = leading {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func trackNumber(_ number: Int?) -> some View {
        Text("\(number ?? 0)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 28, alignment: .trailing)
    }

    private var titleLabel: some View {
        Text(title)
            .lineLimit(1)
    }

    @ViewBuilder private var explicitBadge: some View {
        if isExplicit {
            Text("E")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
        }
    }

    @ViewBuilder private var unavailableLabel: some View {
        if let unavailableReason {
            Label("Unavailable", systemImage: "nosign")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(unavailableReason)
        }
    }

    private var durationLabel: some View {
        Text(Format.duration(duration))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    @ViewBuilder private var qualityBadge: some View {
        if let quality {
            QualityBadge(kind: quality)
        }
    }

    @ViewBuilder private var libraryLabel: some View {
        if let libraryStatus {
            LibraryStatusLabel(status: libraryStatus, compact: true)
        }
    }

    @ViewBuilder private var addButton: some View {
        if add != nil, unavailableReason == nil {
            AddToQueueButton(isQueued: isQueued, add: add)
        }
    }

    private var hasSecondaryMetadata: Bool {
        unavailableReason != nil || quality != nil || libraryStatus != nil || (add != nil && unavailableReason == nil)
    }
}
