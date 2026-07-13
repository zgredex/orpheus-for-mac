import NativeQobuzCore
import SwiftUI

struct NativeSettingsView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SettingsDraft
    @State private var errorMessage: String?

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
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!draft.credentials.isComplete || draft.downloadPath.isEmpty)
            }.padding(.top, 14)
        }
        .padding(DS.Space.xl)
        .frame(width: 540)
    }

    private func chooseFolder() {
        if let url = FileDialog.chooseFolder(startingAt: draft.downloadPath) { draft.downloadPath = url.path }
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
