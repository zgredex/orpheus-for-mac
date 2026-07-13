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
                    TextField("App ID", text: $draft.credentials.appID)
                    SecureField("App secret", text: $draft.credentials.appSecret)
                    SecureField("Auth token", text: $draft.credentials.authToken)
                    LabeledContent("Account region", value: vm.regionDisplay)
                } header: {
                    Text("Qobuz")
                }
                Section("Download") {
                    Picker("Quality", selection: $draft.quality) {
                        ForEach(QobuzQuality.allCases, id: \.self) { quality in
                            Text(quality.displayName).tag(quality)
                        }
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
