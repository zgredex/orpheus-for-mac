import AppKit
import NativeQobuzCore
import SwiftUI

struct NativeContentView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @EnvironmentObject private var account: NativeAccountController
    @EnvironmentObject private var browse: NativeBrowseController
    @EnvironmentObject private var library: NativeLibraryController
    @EnvironmentObject private var downloads: NativeDownloadController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            content(activityPaneHeight: activityPaneHeight(totalWidth: geometry.size.width))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem {
                    RegionBadge(code: account.accountRegion, quality: account.settings.quality)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem {
                    RegionBadge(code: account.accountRegion, quality: account.settings.quality)
                }
            }
            #else
            ToolbarItem {
                RegionBadge(code: account.accountRegion, quality: account.settings.quality)
            }
            #endif
            ToolbarItem {
                Button {
                    if library.isOpen { vm.closeLibrary() }
                    else { vm.openLibrary() }
                } label: {
                    Image(systemName: "books.vertical")
                }
                .help(library.isOpen ? "Close Library" : "Open Library")
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

    private func content(activityPaneHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            NativeInputBar()
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
            Divider()
            HSplitView {
                NativeQueuePane()
                    .frame(
                        minWidth: DS.Pane.queueMinimumWidth,
                        idealWidth: DS.Pane.queueIdealWidth,
                        maxWidth: DS.Pane.queueMaximumWidth,
                        maxHeight: .infinity
                    )
                VSplitView {
                    Group {
                        if library.isOpen { NativeLibraryView().transition(.opacity) }
                        else if browse.isOpen { NativeBrowseView().transition(.opacity) }
                        else { NativePreviewView().transition(.opacity) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                    .layoutPriority(1)
                    .animation(.easeOut(duration: 0.15), value: browse.isOpen)
                    NativeActivityView()
                        .frame(
                            maxWidth: .infinity,
                            minHeight: activityPaneHeight,
                            idealHeight: activityPaneHeight,
                            maxHeight: activityPaneHeight
                        )
                        .layoutPriority(0)
                }
                .frame(
                    minWidth: DS.Pane.workspaceMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            NativeCommandBar()
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(.bar)
        }
    }

    private func activityPaneHeight(totalWidth: CGFloat) -> CGFloat {
        let workspaceWidth = totalWidth - DS.Pane.queueMaximumWidth
        return DS.ActivityPane.preferredHeight(
            activityCount: downloads.activities.count,
            compact: workspaceWidth < DS.Row.activityRegularMinimumWidth,
            accessibility: dynamicTypeSize.isAccessibilitySize
        )
    }
}
