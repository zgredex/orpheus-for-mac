import AppKit
import NativeQobuzCore
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
                    RegionBadge(code: vm.accountRegion, quality: vm.settings.quality)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem {
                    RegionBadge(code: vm.accountRegion, quality: vm.settings.quality)
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
                Button { vm.showDiagnostics = true } label: { Image(systemName: "waveform.path.ecg.rectangle") }
                    .help("Open Diagnostics")
            }
            ToolbarItem {
                Button { vm.showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $vm.showSettings) { NativeSettingsView(draft: vm.settingsDraft) }
        .sheet(isPresented: $vm.showDiagnostics) { NativeLogView() }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            qobuzLog.info("lifecycle.window", "App became active")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            qobuzLog.debug("lifecycle.window", "App resigned active state")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            qobuzLog.notice("lifecycle.system", "System will sleep")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            qobuzLog.notice("lifecycle.system", "System woke from sleep")
        }
    }
}
