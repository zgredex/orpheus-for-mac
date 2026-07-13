import NativeQobuzCore
import SwiftUI

struct NativeLibraryView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @State private var section: LibrarySection = .albums
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
                    Button {
                        section = .problems
                    } label: {
                        Label("\(snapshot.problemCount) problems", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.horizontal, DS.Space.s)
                            .padding(.vertical, DS.Space.xxs)
                            .background(
                                section == .problems ? Color.orange.opacity(0.16) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Show files and index records that need attention")
                }
                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    sectionPicker(snapshot)
                        .frame(width: 600)
                        .clipped()
                    Spacer(minLength: DS.Space.m)
                    scanStatus(snapshot)
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    sectionPicker(snapshot)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    scanStatus(snapshot)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .help(snapshot.rootPath)
        .onAppear { synchronizeSection(with: snapshot) }
        .onChange(of: snapshot.scannedAt) { _, _ in
            selection.formIntersection(Set(snapshot.tracks.map(\.id)))
            synchronizeSection(with: snapshot)
        }
        .onChange(of: section) { _, _ in selection.removeAll() }
    }

    private func sectionPicker(_ snapshot: QobuzArchiveSnapshot) -> some View {
        Picker("Library Section", selection: $section) {
            ForEach(visibleSections(in: snapshot), id: \.self) { value in
                Text("\(value.title)  \(sectionCount(value, in: snapshot))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private func scanStatus(_ snapshot: QobuzArchiveSnapshot) -> some View {
        HStack(spacing: DS.Space.xs) {
            if vm.isArchiveScanning {
                ProgressView().controlSize(.mini)
                Text("Verifying library…")
            } else {
                Text(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private func content(_ snapshot: QobuzArchiveSnapshot) -> some View {
        if section == .problems {
            problemsContent(snapshot)
        } else if let category = section.archiveKind {
            categoryContent(snapshot, category: category)
        }
    }

    @ViewBuilder private func categoryContent(
        _ snapshot: QobuzArchiveSnapshot,
        category: QobuzArchiveKind
    ) -> some View {
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
                            ForEach(entry.tracks) { track in
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

    @ViewBuilder private func problemsContent(_ snapshot: QobuzArchiveSnapshot) -> some View {
        let fileProblems = snapshot.nativeFileProblems
        let indexProblems = snapshot.nativeIndexProblems
        VStack(spacing: 0) {
            problemActions(snapshot)
            Divider()
            if fileProblems.isEmpty && indexProblems.isEmpty {
                ContentUnavailableView(
                    "Library Verified",
                    systemImage: "checkmark.seal.fill",
                    description: Text("Every indexed audio file matches its recorded checksum.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if !fileProblems.isEmpty {
                        Section("File Problems") {
                            ForEach(fileProblems) { problem in
                                problemFileRow(problem)
                                    .tag(problem.id)
                            }
                        }
                    }
                    if !indexProblems.isEmpty {
                        Section("Library Index Problems") {
                            ForEach(indexProblems) { problem in
                                indexProblemRow(problem)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func problemActions(_ snapshot: QobuzArchiveSnapshot) -> some View {
        let repairable = snapshot.nativeFileProblems.filter(\.isAutomaticallyRepairable).count
        let manual = snapshot.problemCount - repairable
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) {
                problemCounts(repairable: repairable, manual: manual)
                Spacer(minLength: DS.Space.m)
                repairButtons
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                problemCounts(repairable: repairable, manual: manual)
                repairButtons
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(.bar)
    }

    private func problemCounts(repairable: Int, manual: Int) -> some View {
        HStack(spacing: DS.Space.m) {
            Label("\(repairable) repairable", systemImage: "wrench.and.screwdriver.fill")
                .foregroundStyle(repairable > 0 ? .green : .secondary)
            if manual > 0 {
                Label("\(manual) manual", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            if vm.isArchiveScanning {
                ProgressView().controlSize(.mini)
                Text("Verifying after changes…")
                    .foregroundStyle(.secondary)
            } else if vm.isDownloading {
                Text("Verification will run automatically when downloads finish.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
    }

    private var repairButtons: some View {
        HStack(spacing: DS.Space.s) {
            Button("Repair Selected", systemImage: "wrench.and.screwdriver") {
                vm.repairArchiveTracks(selectedRepairTracks)
            }
            .buttonStyle(.bordered)
            .disabled(selectedRepairTracks.isEmpty || vm.isDownloading || vm.isArchiveScanning)
            Button("Repair All", systemImage: "wrench.and.screwdriver.fill") {
                showRepairAllConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(repairableTracks.isEmpty || vm.isDownloading || vm.isArchiveScanning)
        }
        .controlSize(.small)
    }

    private func problemFileRow(_ problem: NativeLibraryFileProblem) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: problem.systemImage)
                .font(.title3)
                .foregroundStyle(integrityColor(problem.track.integrity))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(URL(fileURLWithPath: problem.track.relativePath).lastPathComponent)
                    .font(.rowTitle)
                    .lineLimit(1)
                Text(problem.track.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(problem.reasonDetail)
                    .font(.caption2)
                    .foregroundStyle(integrityColor(problem.track.integrity))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            QualityBadge(kind: .archive(problem.track))
            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                integrityLabel(problem.track.integrity)
                Label(
                    problem.isAutomaticallyRepairable ? "Repairable" : "Manual action",
                    systemImage: problem.isAutomaticallyRepairable ? "wrench.and.screwdriver.fill" : "hand.raised.fill"
                )
                .font(.caption2)
                .foregroundStyle(problem.isAutomaticallyRepairable ? .green : .orange)
                .help(problem.repairabilityDetail)
            }
            .frame(width: 112, alignment: .trailing)
            Button { vm.revealArchiveTrack(problem.track) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show expected location in Finder")
        }
        .frame(minHeight: 62)
        .help("\(problem.reasonTitle): \(problem.reasonDetail)\n\(problem.repairabilityDetail)")
    }

    private func indexProblemRow(_ problem: NativeLibraryIndexProblem) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(problem.relativePath == "." ? "Library index" : problem.relativePath)
                    .font(.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Label("Manual action", systemImage: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Button { vm.revealArchiveIssue(problem) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show related location in Finder")
        }
        .frame(minHeight: 54)
        .help(problem.message)
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

    private func visibleSections(in snapshot: QobuzArchiveSnapshot) -> [LibrarySection] {
        var values: [LibrarySection] = [.albums, .tracks, .playlists]
        if snapshot.library.count(of: .unclassified) > 0 { values.append(.older) }
        values.append(.problems)
        return values
    }

    private func sectionCount(_ value: LibrarySection, in snapshot: QobuzArchiveSnapshot) -> Int {
        if value == .problems { return snapshot.problemCount }
        return value.archiveKind.map { snapshot.library.count(of: $0) } ?? 0
    }

    private func synchronizeSection(with snapshot: QobuzArchiveSnapshot) {
        guard section != .problems else { return }
        let visible = visibleSections(in: snapshot)
        guard !visible.contains(section) || sectionCount(section, in: snapshot) == 0 else { return }
        section = visible.first {
            $0 != .problems && sectionCount($0, in: snapshot) > 0
        } ?? .albums
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

    private func integrityColor(_ integrity: QobuzArchiveIntegrity) -> Color {
        switch integrity {
        case .verified: .green
        case .missing, .metadataConflict: .orange
        case .checksumMismatch, .unreadable: .red
        }
    }
}

private enum LibrarySection: String, CaseIterable, Hashable {
    case albums = "Albums"
    case tracks = "Tracks"
    case playlists = "Playlists"
    case older = "Older"
    case problems = "Problems"

    var title: String { rawValue }

    var archiveKind: QobuzArchiveKind? {
        switch self {
        case .albums: .album
        case .tracks: .track
        case .playlists: .playlist
        case .older: .unclassified
        case .problems: nil
        }
    }
}
