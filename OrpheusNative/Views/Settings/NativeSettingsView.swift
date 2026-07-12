import AppKit
import NativeQobuzCore
import SwiftUI

struct NativeSettingsView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = CredentialDraft()
    @State private var quality: QobuzQuality = .hiRes
    @State private var downloadPath = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.weight(.semibold)).padding(.bottom, DS.Space.l)
            Form {
                Section("Qobuz") {
                    TextField("App ID", text: $credentials.appID)
                    SecureField("App secret", text: $credentials.appSecret)
                    SecureField("Auth token", text: $credentials.authToken)
                    LabeledContent("Account region", value: vm.regionDisplay)
                }
                Section("Download") {
                    Picker("Quality", selection: $quality) {
                        Text("Hi-Res FLAC").tag(QobuzQuality.hiRes)
                        Text("Lossless FLAC").tag(QobuzQuality.lossless)
                        Text("MP3 320 kbps").tag(QobuzQuality.mp3)
                    }
                    LabeledContent("Location") {
                        HStack {
                            Text(downloadPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button { chooseFolder() } label: { Image(systemName: "folder") }.help("Choose download folder")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.top, DS.Space.s) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!credentials.isComplete || downloadPath.isEmpty)
            }.padding(.top, 14)
        }
        .padding(DS.Space.xl)
        .frame(width: 540)
        .onAppear {
            credentials = vm.credentials
            quality = vm.settings.quality
            downloadPath = vm.settings.downloadPath
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { downloadPath = url.path }
    }

    private func save() {
        do {
            try vm.saveConfiguration(
                credentials: credentials,
                settings: NativeSettings(downloadPath: downloadPath, quality: quality)
            )
        } catch { errorMessage = error.localizedDescription }
    }
}
