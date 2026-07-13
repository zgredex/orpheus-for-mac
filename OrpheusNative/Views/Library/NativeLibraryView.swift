import NativeQobuzCore
import SwiftUI

struct NativeLibraryView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @State private var category: QobuzArchiveKind = .album
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
        let library = snapshot.library
        return VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.l) {
                Label("\(library.entries.count) downloads", systemImage: "tray.full")
                Label("\(snapshot.tracks.count) files", systemImage: "music.note")
                Label("\(snapshot.verifiedCount) verified", systemImage: "checkmark.seal")
                    .foregroundStyle(snapshot.problemCount == 0 ? .green : .secondary)
                if snapshot.problemCount > 0 {
                    Label("\(snapshot.problemCount) problems", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            HStack(spacing: DS.Space.m) {
                Picker("Library Section", selection: $category) {
                    ForEach(visibleCategories(in: library), id: \.self) { value in
                        Text("\(categoryLabel(value))  \(library.count(of: value))")
                            .monospacedDigit()
                            .tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 500)
                Spacer()
                Text(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .help(snapshot.rootPath)
        .onAppear { synchronizeCategory(with: library) }
        .onChange(of: snapshot.scannedAt) { _, _ in
            selection.formIntersection(Set(snapshot.tracks.map(\.id)))
            synchronizeCategory(with: snapshot.library)
        }
        .onChange(of: category) { _, _ in selection.removeAll() }
    }

    @ViewBuilder private func content(_ snapshot: QobuzArchiveSnapshot) -> some View {
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
                "No \(categoryLabel(category))",
                systemImage: categoryIcon(category),
                description: Text(emptyDescription(category))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(entries) { entry in
                    if entry.kind == .track, let track = entry.tracks.first {
                        standaloneTrackRow(entry, track: track)
                            .tag(track.id)
                    } else {
                        DisclosureGroup {
                            ForEach(Array(entry.tracks.enumerated()), id: \.offset) { _, track in
                                archiveTrackRow(track)
                                    .tag(track.id)
                            }
                        } label: {
                            archiveEntryLabel(entry)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func archiveEntryLabel(_ entry: QobuzArchiveEntry) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: categoryIcon(entry.kind))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.m)
            QualityBadge(kind: entryQualityKind(entry))
            Text(entry.byteCount.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
            entryIntegrityLabel(entry)
            Button { vm.revealArchiveEntry(entry) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .frame(minHeight: 36)
    }

    private func standaloneTrackRow(_ entry: QobuzArchiveEntry, track: QobuzArchiveTrack) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.m)
            trackMetadata(track)
            Button { vm.revealArchiveTrack(track) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .frame(minHeight: 36)
    }

    private func archiveTrackRow(_ track: QobuzArchiveTrack) -> some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(URL(fileURLWithPath: track.relativePath).lastPathComponent)
                    .lineLimit(1)
                Text("Qobuz \(track.qobuzTrackID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.m)
            trackMetadata(track)
            Button { vm.revealArchiveTrack(track) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .frame(minHeight: 32)
    }

    private func trackMetadata(_ track: QobuzArchiveTrack) -> some View {
        Group {
            QualityBadge(kind: .archive(track))
            Text(track.byteCount.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—")
            .foregroundStyle(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
            integrityLabel(track.integrity)
        }
        .font(.caption)
    }

    private var repairableTracks: [QobuzArchiveTrack] {
        vm.archiveSnapshot?.tracks.filter {
            $0.integrity != .verified && QobuzQuality(formatID: $0.formatID) != nil
        } ?? []
    }

    private var selectedRepairTracks: [QobuzArchiveTrack] {
        repairableTracks.filter { selection.contains($0.id) }
    }

    private func visibleCategories(in library: QobuzArchiveLibrary) -> [QobuzArchiveKind] {
        var values: [QobuzArchiveKind] = [.album, .track, .playlist]
        if library.count(of: .unclassified) > 0 { values.append(.unclassified) }
        return values
    }

    private func synchronizeCategory(with library: QobuzArchiveLibrary) {
        let visible = visibleCategories(in: library)
        guard !visible.contains(category) || library.count(of: category) == 0 else { return }
        category = visible.first(where: { library.count(of: $0) > 0 }) ?? .album
    }

    private func categoryLabel(_ value: QobuzArchiveKind) -> String {
        switch value {
        case .album: "Albums"
        case .track: "Tracks"
        case .playlist: "Playlists"
        case .unclassified: "Older"
        }
    }

    private func categoryIcon(_ value: QobuzArchiveKind) -> String {
        switch value {
        case .album: "square.stack"
        case .track: "music.note"
        case .playlist: "music.note.list"
        case .unclassified: "archivebox"
        }
    }

    private func emptyDescription(_ value: QobuzArchiveKind) -> String {
        switch value {
        case .album: "Downloaded albums and artist releases appear here."
        case .track: "Individually downloaded tracks appear here."
        case .playlist: "Downloaded playlists appear here."
        case .unclassified: "Downloads created before Library classification appear here."
        }
    }

    private func entryQualityKind(_ entry: QobuzArchiveEntry) -> QualityBadge.Kind {
        let values = Set(entry.tracks.map(QualityBadge.Kind.archive))
        return values.count == 1 ? values.first ?? .mixed : .mixed
    }

    private func entryIntegrityLabel(_ entry: QobuzArchiveEntry) -> some View {
        let clean = entry.problemCount == 0
        return Label(
            clean ? "Verified" : "\(entry.problemCount) issue\(entry.problemCount == 1 ? "" : "s")",
            systemImage: clean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(clean ? .green : .orange)
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
