import NativeQobuzCore
import SwiftUI

struct NativeLibraryView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @State private var selection = Set<QobuzArchiveTrack.ID>()
    @State private var showRepairAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = vm.archiveSnapshot {
                summary(snapshot)
                Divider()
                content(snapshot)
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
            "Repair \(repairableTracks.count) file\(repairableTracks.count == 1 ? "" : "s")?",
            isPresented: $showRepairAllConfirmation
        ) {
            Button("Repair All Problems") {
                vm.repairArchiveTracks(repairableTracks)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each file will be restored from its exact Qobuz track ID at the archived quality and path.")
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.secondary)
            Text("Library")
                .fontWeight(.semibold)
            if vm.isArchiveScanning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(action: vm.refreshArchive) {
                Image(systemName: "checkmark.shield")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isArchiveScanning || vm.isDownloading)
            .help("Verify Library")
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
            Button(action: vm.closeLibrary) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Library")
        }
        .frame(height: DS.Bar.paneHeaderHeight)
        .padding(.horizontal, DS.Space.l)
    }

    private func summary(_ snapshot: QobuzArchiveSnapshot) -> some View {
        HStack(spacing: DS.Space.l) {
            Label("\(snapshot.albumCount) albums", systemImage: "square.stack")
            Label("\(snapshot.tracks.count) tracks", systemImage: "music.note")
            Label("\(snapshot.verifiedCount) verified", systemImage: "checkmark.seal")
                .foregroundStyle(snapshot.problemCount == 0 ? .green : .secondary)
            if snapshot.problemCount > 0 {
                Label("\(snapshot.problemCount) problems", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .help(snapshot.rootPath)
    }

    @ViewBuilder private func content(_ snapshot: QobuzArchiveSnapshot) -> some View {
        if snapshot.tracks.isEmpty {
            ContentUnavailableView(
                "No Indexed Downloads",
                systemImage: "externaldrive",
                description: Text(snapshot.issues.first?.message ?? "No Orpheus provenance files were found.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(snapshot.tracks, selection: $selection) {
                TableColumn("File") { track in
                    Button {
                        vm.revealArchiveTrack(track)
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(URL(fileURLWithPath: track.relativePath).lastPathComponent)
                                .lineLimit(1)
                            Text(track.qobuzTrackID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(track.relativePath)
                }
                .width(min: 190, ideal: 300)

                TableColumn("Album ID", value: \.qobuzAlbumID)
                    .width(min: 100, ideal: 130)

                TableColumn("Quality") { track in
                    Text(qualityLabel(track))
                        .lineLimit(1)
                }
                .width(min: 90, ideal: 120)

                TableColumn("Size") { track in
                    Text(track.byteCount.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "—")
                    .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Integrity") { track in
                    integrityLabel(track.integrity)
                }
                .width(min: 105, ideal: 130)
            }
            .onChange(of: snapshot.scannedAt) { _, _ in
                selection.formIntersection(Set(snapshot.tracks.map(\.id)))
            }
        }
    }

    private var repairableTracks: [QobuzArchiveTrack] {
        vm.archiveSnapshot?.tracks.filter {
            $0.integrity != .verified && QobuzQuality(formatID: $0.formatID) != nil
        } ?? []
    }

    private var selectedRepairTracks: [QobuzArchiveTrack] {
        repairableTracks.filter { selection.contains($0.id) }
    }

    private func qualityLabel(_ track: QobuzArchiveTrack) -> String {
        if track.formatID == QobuzQuality.mp3.formatID { return "MP3 320" }
        guard let bitDepth = track.bitDepth, let samplingRate = track.samplingRate else {
            return track.formatID == QobuzQuality.hiRes.formatID ? "Hi-Res FLAC" : "FLAC"
        }
        return "\(bitDepth)-bit / \(samplingRate.formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }

    private func integrityLabel(_ integrity: QobuzArchiveIntegrity) -> some View {
        let value: (String, String, Color) = switch integrity {
        case .verified: ("Verified", "checkmark.seal.fill", .green)
        case .missing: ("Missing", "questionmark.folder", .orange)
        case .checksumMismatch: ("Changed", "exclamationmark.triangle.fill", .red)
        case .metadataConflict: ("Conflict", "arrow.trianglehead.2.clockwise.rotate.90", .orange)
        case .unreadable: ("Unreadable", "xmark.octagon.fill", .red)
        }
        return Label(value.0, systemImage: value.1)
            .font(.caption)
            .foregroundStyle(value.2)
    }
}
