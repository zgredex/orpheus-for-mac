import AppKit
import SwiftUI

struct NativeContentView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            NativeInputBar()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            HSplitView {
                NativeQueuePane()
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                VSplitView {
                    Group {
                        if vm.isBrowseOpen { NativeBrowseView() }
                        else { NativePreviewView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                    NativeActivityView()
                        .frame(minHeight: 130, idealHeight: 190)
                }
                .frame(minWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            NativeCommandBar()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                RegionBadge(code: vm.accountRegion)
                Button { vm.showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $vm.showSettings) { NativeSettingsView() }
        .alert("Orpheus Native", isPresented: Binding(
            get: { vm.notice != nil },
            set: { if !$0 { vm.notice = nil } }
        )) {
            Button("OK") { vm.notice = nil }
        } message: {
            Text(vm.notice ?? "")
        }
    }
}
