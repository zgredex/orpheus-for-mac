import NativeQobuzCore
import SwiftUI

struct AlbumPreview: View {
    let album: QobuzAlbum
    var onOpenArtist: (() -> Void)?
    var onOpenLabel: (() -> Void)?
    var onAddTrack: ((QobuzTrack) -> Void)?
    var isTrackQueued: ((QobuzTrack) -> Bool)?
    var libraryStatus: NativeLibraryStatus?
    var trackLibraryStatus: ((QobuzTrack) -> NativeLibraryStatus?)?
    var trackAvailabilityMessage: ((QobuzTrack) -> String?)?
    var selectedTrackIDs: Set<QobuzID>?
    var onToggleTrackSelection: ((QobuzID) -> Void)?
    var onSelectAllTracks: (() -> Void)?
    var onClearTrackSelection: (() -> Void)?

    var body: some View {
        PreviewScaffold(
            header: PreviewHeader(
                artworkURL: album.image?.bestURL,
                title: album.displayTitle,
                subtitle: album.albumArtistDisplayName,
                onSubtitleTap: onOpenArtist,
                metadata: CatalogFormat.albumFacts(album.catalogMetadata) + [trackCountText] + [album.label].compactMap { $0 },
                badges: badges,
                catalogMarkers: CatalogFormat.albumMarkers(album.catalogMetadata)
            ),
            headerAccessory: {
                EditorialHeroPanel(
                    heading: "About this album",
                    summary: album.catalogMetadata.catchline,
                    editorialDescription: album.catalogMetadata.editorialDescription
                )
            }
        ) {
            VStack(spacing: 0) {
                if let label = album.label, onOpenLabel != nil {
                    HStack {
                        Button { onOpenLabel?() } label: {
                            Label(label, systemImage: "building.2")
                        }
                        .buttonStyle(.borderless)
                        .help("Browse \(label)")
                        Spacer()
                    }
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
                List(album.tracks, id: \.id) { track in
                    TrackListRow(
                        leading: .number(track.trackNumber),
                        title: track.displayTitle,
                        isExplicit: track.parentalWarning,
                        duration: track.duration,
                        isQueued: isTrackQueued?(track) ?? false,
                        libraryStatus: trackLibraryStatus?(track),
                        quality: .catalog(track, fallback: album),
                        unavailableReason: trackAvailabilityMessage?(track),
                        isSelected: selectedTrackIDs.map { $0.contains(track.id) },
                        toggleSelection: onToggleTrackSelection.map { toggle in { toggle(track.id) } },
                        add: track.accountAvailabilityIssue == nil
                            ? onAddTrack.map { add in { add(track) } }
                            : nil
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
                    "\(selectedTrackIDs.count) of \(album.availableTracks.count) selected",
                    systemImage: "checklist"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button("All", action: { onSelectAllTracks?() })
                    .buttonStyle(.borderless)
                    .disabled(selectedTrackIDs.count == album.availableTracks.count)
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

    private var badges: [QualityBadge.Kind] {
        var result: [QualityBadge.Kind] = [.catalog(album)]
        if album.parentalWarning { result.append(.explicitContent) }
        return result
    }

    private var trackCountText: String {
        let available = album.availableTracks.count
        guard album.unavailableTrackCount > 0 else { return "\(available) tracks" }
        return "\(available) of \(album.tracks.count) tracks available"
    }
}
