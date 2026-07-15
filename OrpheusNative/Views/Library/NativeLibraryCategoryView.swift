import NativeQobuzCore
import SwiftUI

struct NativeLibraryCategoryView: View {
    let snapshot: QobuzArchiveSnapshot
    let category: QobuzArchiveKind
    @Binding var selection: Set<QobuzArchiveTrack.ID>
    let onRevealEntry: (QobuzArchiveEntry) -> Void
    let onRevealTrack: (QobuzArchiveTrack) -> Void

    var body: some View {
        let entries = snapshot.library.entries(of: category)
        if snapshot.tracks.isEmpty {
            ContentUnavailableView(
                "No Indexed Downloads",
                systemImage: "externaldrive",
                description: Text(snapshot.issues.first?.message ?? "No Orpheus provenance files were found.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No \(NativeLibraryPresentation.label(for: category))",
                systemImage: NativeLibraryPresentation.icon(for: category),
                description: Text(NativeLibraryPresentation.emptyDescription(for: category))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(entries) { entry in
                    if entry.kind == .track, let track = entry.tracks.first {
                        NativeLibraryStandaloneTrackRow(
                            entry: entry,
                            track: track,
                            onReveal: { onRevealTrack(track) }
                        )
                        .tag(track.id)
                    } else {
                        DisclosureGroup {
                            ForEach(entry.tracks) { track in
                                NativeLibraryTrackRow(track: track, onReveal: { onRevealTrack(track) })
                                    .tag(track.id)
                            }
                        } label: {
                            NativeLibraryEntryRow(entry: entry, onReveal: { onRevealEntry(entry) })
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
