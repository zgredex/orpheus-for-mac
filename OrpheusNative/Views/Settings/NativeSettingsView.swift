import NativeQobuzCore
import SwiftUI

struct NativeSettingsView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SettingsDraft
    @State private var errorMessage: String?
    @State private var adoptionPlan: QobuzLibraryAdoptionPlan?
    @State private var isInspectingLibrary = false
    @State private var isAdoptingLibrary = false

    init(draft: SettingsDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.weight(.semibold)).padding(.bottom, DS.Space.l)
            Form {
                Section {
                    TextField("App ID (not User ID)", text: $draft.credentials.appID)
                        .help("Qobuz application ID. Orpheus for Mac never stores or sends the account User ID.")
                    SecureField("App secret", text: $draft.credentials.appSecret)
                    SecureField("Auth token", text: $draft.credentials.authToken)
                    LabeledContent("Account region", value: vm.regionDisplay)
                } header: {
                    Text("Qobuz")
                }
                Section("Download") {
                    LabeledContent("Quality") {
                        QualitySelector(selection: $draft.quality)
                    }
                    LabeledContent("Location") {
                        HStack {
                            Text(draft.downloadPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button { chooseFolder() } label: { Image(systemName: "folder") }.help("Choose download folder")
                        }
                    }
                }
                Section("Existing Library") {
                    HStack {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text("Adopt an Orpheus Library")
                            Text("Inspects provenance and verifies checksums before changing this Mac's Library location.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Inspect Folder…") { inspectExistingLibrary() }
                            .disabled(isInspectingLibrary || isAdoptingLibrary || vm.isDownloading)
                    }
                    if isInspectingLibrary {
                        HStack(spacing: DS.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Reading provenance and verifying files…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let adoptionPlan {
                        adoptionSummary(adoptionPlan)
                    }
                }
            }
            .formStyle(.grouped)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, DS.Space.s)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !draft.credentials.isComplete
                            || draft.downloadPath.isEmpty
                            || isInspectingLibrary
                            || isAdoptingLibrary
                    )
            }.padding(.top, 14)
        }
        .padding(DS.Space.xl)
        .frame(width: 540)
    }

    private func chooseFolder() {
        if let url = FileDialog.chooseFolder(startingAt: draft.downloadPath) {
            draft.downloadPath = url.path
            adoptionPlan = nil
        }
    }

    @ViewBuilder private func adoptionSummary(_ plan: QobuzLibraryAdoptionPlan) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Label("\(plan.snapshot.tracks.count) files", systemImage: "music.note")
                Label("\(plan.snapshot.verifiedCount) verified", systemImage: "checkmark.seal")
                    .foregroundStyle(plan.snapshot.problemCount == 0 ? .green : .secondary)
                if plan.snapshot.problemCount > 0 {
                    Label("\(plan.snapshot.problemCount) problems", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(adoptionActionTitle(plan.manifestAction))
                        .font(.callout.weight(.semibold))
                    Text(plan.root.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("\(plan.proposedCollectionCount) recoverable collection\(plan.proposedCollectionCount == 1 ? "" : "s"). The folder is inspected again before adoption.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isAdoptingLibrary ? "Adopting…" : "Adopt Library") {
                    adoptExistingLibrary(plan)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdoptingLibrary || !draft.credentials.isComplete)
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func adoptionActionTitle(_ action: QobuzLibraryManifestAction) -> String {
        switch action {
        case .none: "Index is valid and portable"
        case .create: "A Library index will be created"
        case .update: "Moved collections will be reconciled"
        case .repair: "The damaged Library index will be rebuilt"
        }
    }

    private func inspectExistingLibrary() {
        guard let root = FileDialog.chooseFolder(startingAt: draft.downloadPath) else { return }
        errorMessage = nil
        adoptionPlan = nil
        isInspectingLibrary = true
        Task {
            defer { isInspectingLibrary = false }
            do {
                adoptionPlan = try await vm.inspectLibraryForAdoption(at: root)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func adoptExistingLibrary(_ plan: QobuzLibraryAdoptionPlan) {
        errorMessage = nil
        isAdoptingLibrary = true
        Task {
            defer { isAdoptingLibrary = false }
            do {
                try await vm.adoptLibrary(at: plan.root, draft: draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        do { try vm.saveConfiguration(draft) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct QualitySelector: View {
    @Binding var selection: QobuzQuality

    var body: some View {
        HStack(spacing: 1) {
            ForEach(QobuzQuality.allCases, id: \.self) { quality in
                Button {
                    selection = quality
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Circle()
                            .fill(QualityBadge.Kind.target(quality).color)
                            .frame(width: 8, height: 8)
                        Text(quality.displayName)
                            .lineLimit(1)
                    }
                    .font(.caption.weight(selection == quality ? .semibold : .regular))
                    .foregroundStyle(selection == quality ? Color.primary : Color.secondary)
                    .padding(.horizontal, DS.Space.s)
                    .frame(height: 28)
                    .background {
                        if selection == quality {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.accentColor.opacity(0.18))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Download as \(quality.displayName)")
                .accessibilityLabel(quality.displayName)
                .accessibilityAddTraits(selection == quality ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }
}
