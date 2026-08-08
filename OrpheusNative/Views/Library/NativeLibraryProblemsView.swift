import NativeQobuzCore
import SwiftUI

struct NativeLibraryProblemsView: View {
    let snapshot: QobuzArchiveSnapshot
    let isScanning: Bool
    let isDownloading: Bool
    @Binding var selection: Set<QobuzArchiveTrack.ID>
    let onRepair: ([QobuzArchiveTrack]) -> Void
    let onRepairAll: () -> Void
    let onRevealTrack: (QobuzArchiveTrack) -> Void
    let onRevealIssue: (NativeLibraryIndexProblem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            actions
            Divider()
            if snapshot.nativeFileProblems.isEmpty && snapshot.nativeIndexProblems.isEmpty {
                ContentUnavailableView(
                    "Library Verified",
                    systemImage: "checkmark.seal.fill",
                    description: Text("Every indexed audio file matches its recorded checksum.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                problemList
            }
        }
    }

    private var actions: some View {
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
                repairButtons.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(.bar)
    }

    private var problemList: some View {
        List(selection: $selection) {
            if !snapshot.nativeFileProblems.isEmpty {
                Section("File Problems") {
                    ForEach(snapshot.nativeFileProblems) { problem in
                        NativeLibraryProblemFileRow(problem: problem, onReveal: { onRevealTrack(problem.track) })
                            .tag(problem.id)
                    }
                }
            }
            if !snapshot.nativeIndexProblems.isEmpty {
                Section("Library Index Problems") {
                    ForEach(snapshot.nativeIndexProblems) { problem in
                        NativeLibraryIndexProblemRow(problem: problem, onReveal: { onRevealIssue(problem) })
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func problemCounts(repairable: Int, manual: Int) -> some View {
        HStack(spacing: DS.Space.m) {
            Label("\(repairable) repairable", systemImage: "wrench.and.screwdriver.fill")
                .foregroundStyle(repairable > 0 ? .green : .secondary)
            if manual > 0 {
                Label("\(manual) manual", systemImage: "hand.raised.fill").foregroundStyle(.orange)
            }
            if isScanning {
                ProgressView().controlSize(.mini)
                Text("Verifying after changes…").foregroundStyle(.secondary)
            } else if isDownloading {
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
                onRepair(selectedRepairTracks)
            }
            .buttonStyle(.bordered)
            .disabled(selectedRepairTracks.isEmpty || isDownloading || isScanning)
            Button("Repair All", systemImage: "wrench.and.screwdriver.fill", action: onRepairAll)
                .buttonStyle(.borderedProminent)
                .disabled(repairableTracks.isEmpty || isDownloading || isScanning)
        }
        .controlSize(.small)
    }

    private var repairableTracks: [QobuzArchiveTrack] {
        snapshot.tracks.filter(\.isAutomaticallyRepairable)
    }

    private var selectedRepairTracks: [QobuzArchiveTrack] {
        repairableTracks.filter { selection.contains($0.id) }
    }
}

private struct NativeLibraryProblemFileRow: View {
    let problem: NativeLibraryFileProblem
    let onReveal: () -> Void

    var body: some View {
        NativeLibraryResponsiveRow {
            HStack(spacing: DS.Space.m) {
                problemIcon
                problemDescription
            }
        } metadata: {
            HStack(spacing: DS.Space.m) {
                QualityBadge(kind: .archive(problem.track))
                integrityBlock
                    .frame(width: DS.Column.libraryIntegrity, alignment: .trailing)
            }
        } action: {
            revealButton
        }
        .frame(minHeight: 62)
        .help("\(problem.reasonTitle): \(problem.reasonDetail)\n\(problem.repairabilityDetail)")
    }

    private var problemIcon: some View {
        Image(systemName: problem.systemImage)
            .font(.title3)
            .foregroundStyle(presentation.color)
            .frame(width: 24)
    }

    private var problemDescription: some View {
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
                .foregroundStyle(presentation.color)
                .lineLimit(2)
        }
    }

    private var integrityBlock: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            NativeLibraryIntegrityLabel(integrity: problem.track.integrity)
            Label(
                problem.isAutomaticallyRepairable ? "Repairable" : "Manual action",
                systemImage: problem.isAutomaticallyRepairable
                    ? "wrench.and.screwdriver.fill"
                    : "hand.raised.fill"
            )
            .font(.caption2)
            .foregroundStyle(problem.isAutomaticallyRepairable ? .green : .orange)
            .fixedSize()
            .help(problem.repairabilityDetail)
        }
    }

    private var revealButton: some View {
        Button(action: onReveal) { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show expected location in Finder")
    }

    private var presentation: (label: String, icon: String, color: Color) {
        NativeLibraryPresentation.integrityPresentation(problem.track.integrity)
    }
}

private struct NativeLibraryIndexProblemRow: View {
    let problem: NativeLibraryIndexProblem
    let onReveal: () -> Void

    var body: some View {
        NativeLibraryResponsiveRow {
            HStack(spacing: DS.Space.m) {
                problemIcon
                problemDescription
            }
        } metadata: {
            manualLabel
        } action: {
            revealButton
        }
        .frame(minHeight: 54)
        .help(problem.message)
    }

    private var problemIcon: some View {
        Image(systemName: "doc.text.magnifyingglass")
            .font(.title3)
            .foregroundStyle(.orange)
            .frame(width: 24)
    }

    private var problemDescription: some View {
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
    }

    private var manualLabel: some View {
        Label("Manual action", systemImage: "hand.raised.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var revealButton: some View {
        Button(action: onReveal) { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show related location in Finder")
    }
}
