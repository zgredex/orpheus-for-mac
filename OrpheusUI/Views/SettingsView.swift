import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vm: MainViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tempAppID = ""
    @State private var tempAppSecret = ""
    @State private var tempAuthToken = ""
    @State private var tempUserID = ""
    @State private var tempDownloadPath = ""
    @State private var tempQuality = "hifi"
    @State private var isTesting = false
    @State private var testResult: TestResult?

    var body: some View {
        NavigationStack {
            Form {
                Section("Qobuz Credentials") {
                    LabeledContent("Account Region") {
                        Text(vm.accountRegionDisplay)
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                    }

                    LabeledContent("App ID") {
                        TextField("App ID", text: $tempAppID)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("App Secret") {
                        SecureField("App Secret", text: $tempAppSecret)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Auth Token") {
                        SecureField("Auth Token", text: $tempAuthToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    LabeledContent("User ID") {
                        TextField("User ID", text: $tempUserID)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button(action: testConnection) {
                            Label("Test Connection", systemImage: "network")
                        }
                        .disabled(isTesting || hasMissingTestCredentials)

                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        }

                        if let testResult {
                            Label(testResult.message, systemImage: testResult.systemImage)
                                .foregroundStyle(testResult.color)
                                .font(.caption)
                        }
                    }
                }

                Section("Download") {
                    Picker("Quality", selection: $tempQuality) {
                        Text("FLAC 24-bit").tag("hifi")
                        Text("FLAC 16-bit").tag("lossless")
                        Text("MP3 320 kbps").tag("high")
                    }

                    LabeledContent("Download Path") {
                        HStack(spacing: 10) {
                            Text(vm.resolvedDownloadPath(for: tempDownloadPath))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Button(action: chooseDirectory) {
                                Label("Choose", systemImage: "folder")
                            }
                        }
                    }
                }

                Section("Runtime") {
                    LabeledContent("Runtime Copy") {
                        Text(vm.runtimePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 560, minHeight: 460)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.applySettings(
                            appID: tempAppID,
                            appSecret: tempAppSecret,
                            authToken: tempAuthToken,
                            userID: tempUserID,
                            downloadPath: tempDownloadPath,
                            quality: tempQuality
                        )
                        dismiss()
                    }
                }
            }
            .onAppear(perform: populateFields)
        }
    }

    private var hasMissingTestCredentials: Bool {
        [tempAppID, tempAppSecret, tempAuthToken].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func populateFields() {
        guard let settings = vm.settings else { return }
        tempAppID = settings.qobuzAppID
        tempAppSecret = settings.qobuzAppSecret
        tempAuthToken = settings.qobuzAuthToken
        tempUserID = settings.qobuzUserID
        tempDownloadPath = settings.downloadPath
        tempQuality = settings.downloadQuality.isEmpty ? "hifi" : settings.downloadQuality
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            let result = await vm.testConnection(
                appID: tempAppID,
                appSecret: tempAppSecret,
                authToken: tempAuthToken
            )
            switch result {
            case .success(let region):
                testResult = .success("OK (\(RegionDisplay.display(region)))")
            case .failure(let error):
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK, let path = panel.url?.path {
            tempDownloadPath = path
        }
    }
}

private struct TestResult {
    let message: String
    let color: Color
    let systemImage: String

    static func success(_ message: String) -> TestResult {
        TestResult(message: message, color: .green, systemImage: "checkmark.circle.fill")
    }

    static func failure(_ message: String) -> TestResult {
        TestResult(message: message, color: .red, systemImage: "xmark.circle.fill")
    }
}
