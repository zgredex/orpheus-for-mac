import AppKit
import SwiftUI

struct NativeContentView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            NativeInputBar()
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
            Divider()
            HSplitView {
                NativeQueuePane()
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
                VSplitView {
                    Group {
                        if vm.isLibraryOpen { NativeLibraryView().transition(.opacity) }
                        else if vm.isBrowseOpen { NativeBrowseView().transition(.opacity) }
                        else { NativePreviewView().transition(.opacity) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.15), value: vm.isBrowseOpen)
                    NativeActivityView()
                        .frame(maxWidth: .infinity, minHeight: 130, idealHeight: 190)
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            NativeCommandBar()
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(.bar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem {
                    RegionBadge(code: vm.accountRegion, quality: vm.settings.quality.displayName)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem {
                    RegionBadge(code: vm.accountRegion, quality: vm.settings.quality.displayName)
                }
            }
            ToolbarItem {
                Button {
                    if vm.isLibraryOpen { vm.closeLibrary() }
                    else { vm.openLibrary() }
                } label: {
                    Image(systemName: "books.vertical")
                }
                .help(vm.isLibraryOpen ? "Close Library" : "Open Library")
            }
            ToolbarItem {
                Button { vm.showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $vm.showSettings) { NativeSettingsView(draft: vm.settingsDraft) }
        .alert("Orpheus Native", isPresented: Binding(
            get: { vm.notice != nil },
            set: { if !$0 { vm.notice = nil } }
        )) {
            Button("OK") { vm.notice = nil }
        } message: {
            Text(vm.notice ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            vm.prepareForTermination()
        }
    }
}
