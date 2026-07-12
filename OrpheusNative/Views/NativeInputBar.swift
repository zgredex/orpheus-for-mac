import AppKit
import SwiftUI

struct NativeInputBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Paste Qobuz links or search", text: $vm.input)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(vm.submitInput)
            if !vm.input.isEmpty {
                Button { vm.input = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
            Divider().frame(height: 20)
            Button(action: importText) { Image(systemName: "doc.badge.plus") }
                .help("Import links from text file")
            Button(action: vm.submitInput) { Image(systemName: "arrow.right.circle.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add links or search")
        }
        .padding(.horizontal, 10)
        .frame(height: DS.Bar.inputHeight)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .onAppear { focused = true }
    }

    private func importText() {
        guard let url = FileDialog.chooseLinksFile() else { return }
        vm.importLinks(from: url)
    }
}
