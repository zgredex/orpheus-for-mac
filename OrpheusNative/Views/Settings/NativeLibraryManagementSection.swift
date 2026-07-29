import NativeQobuzCore
import SwiftUI

struct NativeLibraryManagementSection: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Binding var draft: SettingsDraft
    @Binding var errorMessage: String?
    @State private var relocationDestination: URL?
    @State private var showRelocationConfirmation = false
    @State private var showPruneConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var resultMessage: String?

    var body: some View {
        sectionContent
            .alert("Relocate Library?", isPresented: $showRelocationConfirmation) {
                Button("Cancel", role: .cancel) { relocationDestination = nil }
                Button("Relocate") { relocate() }
            } message: {
                Text(relocationMessage)
            }
            .alert(pruneConfirmationTitle, isPresented: $showPruneConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Prune Problems", role: .destructive) { prune() }
            } message: {
                Text("Problematic tracked files will be deleted, their manifests will be reconciled, and the Library will be verified again.")
            }
            .alert("Delete all Orpheus Library content?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Library", role: .destructive) { deleteLibrary() }
            } message: {
                Text(deleteConfirmationMessage)
            }
    }

    private var sectionContent: some View {
        Section("Library Management") {
            currentLibraryRow
            indexedContentRow
            operationProgress
            relocationRow
            pruneRow
            deleteRow
            if let resultMessage {
                Label(resultMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var currentLibraryRow: some View {
        LabeledContent("Current Library") {
            Text(vm.settings.downloadPath)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private var indexedContentRow: some View {
        if let snapshot = vm.archiveSnapshot {
            LabeledContent("Indexed content") {
                Text(summary(snapshot))
                    .foregroundStyle(snapshot.problemCount == 0 ? Color.secondary : Color.orange)
            }
        }
    }

    @ViewBuilder private var operationProgress: some View {
        if let label = vm.libraryManagement.phase.label {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var relocationRow: some View {
        managementRow(
            title: "Relocate Library",
            detail: "Copies only Orpheus-managed content, hashes every file, rescans it, then removes the old managed copy."
        ) {
            Button("Relocate…") { chooseRelocationDestination() }
                .disabled(!canRelocate)
        }
    }

    private var pruneRow: some View {
        managementRow(
            title: "Prune Problems",
            detail: "Removes problematic tracked files and repairs their provenance and checksum records."
        ) {
            Button("Prune…", role: .destructive) { showPruneConfirmation = true }
                .disabled(prunableProblemCount == 0 || operationsDisabled)
        }
    }

    private var deleteRow: some View {
        managementRow(
            title: "Delete Library",
            detail: "Deletes provenance-backed Orpheus content. Unrelated files in the selected folder are preserved."
        ) {
            Button("Delete…", role: .destructive) { showDeleteConfirmation = true }
                .disabled(trackCount == 0 || operationsDisabled)
        }
    }

    private func managementRow<Action: View>(
        title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }

    private var trackCount: Int { vm.archiveSnapshot?.tracks.count ?? 0 }
    private var problemCount: Int { vm.archiveSnapshot?.problemCount ?? 0 }
    private var prunableProblemCount: Int {
        vm.archiveSnapshot?.tracks.count { $0.integrity != .verified } ?? 0
    }
    private var operationsDisabled: Bool {
        vm.isDownloading || vm.isArchiveScanning || vm.libraryManagement.isWorking
    }
    private var canRelocate: Bool {
        trackCount > 0 && problemCount == 0 && !operationsDisabled
    }
    private var relocationMessage: String {
        let path = relocationDestination?.path ?? "the selected empty folder"
        return "The verified Library will be copied to \(path). The destination must be empty. The active location changes only after every copied file and the rebuilt index verify."
    }
    private var pruneConfirmationTitle: String {
        "Prune \(prunableProblemCount) tracked problem\(prunableProblemCount == 1 ? "" : "s")?"
    }
    private var deleteConfirmationMessage: String {
        "This permanently deletes \(trackCount) indexed track\(trackCount == 1 ? "" : "s") and managed sidecars. Unrelated files and the selected Library folder itself remain."
    }

    private func summary(_ snapshot: QobuzArchiveSnapshot) -> String {
        let problems = snapshot.problemCount == 0 ? "verified" : "\(snapshot.problemCount) problems"
        return "\(snapshot.tracks.count) tracks · \(problems)"
    }

    private func chooseRelocationDestination() {
        guard let destination = FileDialog.chooseFolder(startingAt: vm.settings.downloadPath) else { return }
        relocationDestination = destination
        errorMessage = nil
        resultMessage = nil
        showRelocationConfirmation = true
    }

    private func relocate() {
        guard let destination = relocationDestination else { return }
        Task {
            do {
                resultMessage = try await vm.libraryManagement.relocate(
                    to: destination,
                    downloadIsActive: vm.isDownloading
                )
                draft.downloadPath = vm.settings.downloadPath
                relocationDestination = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prune() {
        Task {
            do {
                let result = try await vm.libraryManagement.pruneProblems(
                    downloadIsActive: vm.isDownloading
                )
                resultMessage = "Pruned \(result.removedTrackCount) tracked problem\(result.removedTrackCount == 1 ? "" : "s")."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteLibrary() {
        Task {
            do {
                let result = try await vm.libraryManagement.deleteLibrary(
                    downloadIsActive: vm.isDownloading
                )
                resultMessage = "Deleted \(result.removedTrackCount) indexed track\(result.removedTrackCount == 1 ? "" : "s")."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
