import NativeQobuzCore
import SwiftUI

struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]
    var artworkURL: URL? = nil
    var metadata: [String] = []
    var collectionDescription: String?
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?
    var trackAvailabilityMessage: ((QobuzTrack) -> String?)?
    var selectedTrackIDs: Set<QobuzID>?
    var onToggleTrackSelection: ((QobuzID) -> Void)?
    var onSelectAllTracks: (() -> Void)?
    var onClearTrackSelection: (() -> Void)?

    var body: some View {
        PreviewScaffold(header: PreviewHeader(
            artworkURL: artworkURL,
            placeholderSymbol: "music.note.list",
            title: title,
            subtitle: subtitle,
            metadata: metadata + [trackCountText]
        )) {
            VStack(spacing: 0) {
                if let collectionDescription, !collectionDescription.isEmpty {
                    Text(collectionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Space.s)
                    Divider()
                }
                if let libraryStatus {
                    HStack {
                        LibraryStatusLabel(status: libraryStatus)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
                    Divider()
                }
                selectionBar
                List(tracks, id: \.id) { track in
                    TrackListRow(
                        leading: .artist(track.performer?.name ?? "Unknown Artist"),
                        title: track.displayTitle,
                        isExplicit: track.parentalWarning,
                        duration: track.duration,
                        libraryStatus: trackLibraryStatus?(track),
                        quality: .catalog(track),
                        unavailableReason: trackAvailabilityMessage?(track),
                        isSelected: selectedTrackIDs.map { $0.contains(track.id) },
                        toggleSelection: onToggleTrackSelection.map { toggle in { toggle(track.id) } }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if let selectedTrackIDs, onToggleTrackSelection != nil {
            HStack(spacing: DS.Space.s) {
                Label(
                    "\(selectedTrackIDs.count) of \(availableTrackCount) selected",
                    systemImage: "checklist"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button("All", action: { onSelectAllTracks?() })
                    .buttonStyle(.borderless)
                    .disabled(selectedTrackIDs.count == availableTrackCount)
                Button("None", action: { onClearTrackSelection?() })
                    .buttonStyle(.borderless)
                    .disabled(selectedTrackIDs.isEmpty)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(Color.secondary.opacity(0.08))
            Divider()
        }
    }

    private var trackCountText: String {
        let available = availableTrackCount
        guard available != tracks.count else { return "\(available) tracks" }
        return "\(available) of \(tracks.count) tracks available"
    }

    private var availableTrackCount: Int {
        tracks.filter { $0.accountAvailabilityIssue == nil }.count
    }
}
