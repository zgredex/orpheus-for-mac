import NativeQobuzCore
import SwiftUI

struct NativeLibraryView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @State private var section: NativeLibrarySection = .albums
    @State private var selection = Set<QobuzArchiveTrack.ID>()
    @State private var showRepairAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = vm.archiveSnapshot {
                NativeLibrarySummaryBar(
                    snapshot: snapshot,
                    isScanning: vm.isArchiveScanning,
                    section: $section
                )
                Divider()
                content(snapshot)
                    .onAppear { synchronize(with: snapshot) }
                    .onChange(of: snapshot.scannedAt) { _, _ in
                        selection.formIntersection(Set(snapshot.tracks.map(\.id)))
                        synchronize(with: snapshot)
                    }
                    .onChange(of: section) { _, _ in selection.removeAll() }
            } else if vm.isArchiveScanning {
                ProgressView("Reading provenance and verifying checksums...")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Library Not Indexed",
                    systemImage: "books.vertical",
                    description: Text("Refresh to scan the selected download folder.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "Repair \(repairableTracks.count) repairable file\(repairableTracks.count == 1 ? "" : "s")?",
            isPresented: $showRepairAllConfirmation
        ) {
            Button("Repair All Repairable Files") {
                vm.repairArchiveTracks(repairableTracks)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each file will be restored from its exact Qobuz track ID at the archived quality and path.")
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "books.vertical").foregroundStyle(.secondary)
            Text("Library").fontWeight(.semibold)
            if vm.isArchiveScanning { ProgressView().controlSize(.small) }
            Spacer()
            Button(action: { vm.refreshArchive(fullVerification: true) }) {
                Image(systemName: "checkmark.shield")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isArchiveScanning || vm.isDownloading)
            .help("Verify Library")
            if section != .problems {
                Button {
                    vm.repairArchiveTracks(selectedRepairTracks)
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderless)
                .disabled(selectedRepairTracks.isEmpty || vm.isDownloading || vm.isArchiveScanning)
                .help(selectedRepairTracks.isEmpty ? "Select files that need attention" : "Repair Selected")
                Menu {
                    Button("Repair All Problems", systemImage: "wrench.and.screwdriver") {
                        showRepairAllConfirmation = true
                    }
                    .disabled(repairableTracks.isEmpty || vm.isDownloading || vm.isArchiveScanning)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Library Actions")
            }
            Button {
                vm.showSettings = true
            } label: {
                Image(systemName: "externaldrive.badge.timemachine")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isDownloading || vm.libraryManagement.isWorking)
            .help("Relocate, Prune, or Delete Library")
            Button(action: vm.closeLibrary) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close Library")
        }
        .frame(height: DS.Bar.paneHeaderHeight)
        .padding(.horizontal, DS.Space.l)
    }

    @ViewBuilder
    private func content(_ snapshot: QobuzArchiveSnapshot) -> some View {
        if section == .problems {
            NativeLibraryProblemsView(
                snapshot: snapshot,
                isScanning: vm.isArchiveScanning,
                isDownloading: vm.isDownloading,
                selection: $selection,
                onRepair: vm.repairArchiveTracks,
                onRepairAll: { showRepairAllConfirmation = true },
                onRevealTrack: vm.revealArchiveTrack,
                onRevealIssue: vm.revealArchiveIssue
            )
        } else if let category = section.archiveKind {
            NativeLibraryCategoryView(
                snapshot: snapshot,
                category: category,
                selection: $selection,
                onRevealEntry: vm.revealArchiveEntry,
                onRevealTrack: vm.revealArchiveTrack
            )
        }
    }

    private var repairableTracks: [QobuzArchiveTrack] {
        vm.archiveSnapshot?.tracks.filter {
            $0.integrity != .verified && $0.audioFormat != nil
        } ?? []
    }

    private var selectedRepairTracks: [QobuzArchiveTrack] {
        repairableTracks.filter { selection.contains($0.id) }
    }

    private func synchronize(with snapshot: QobuzArchiveSnapshot) {
        section = NativeLibraryPresentation.synchronizedSection(section, with: snapshot)
    }
}
