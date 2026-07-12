import SwiftUI

struct NativeActivityView: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Activity", count: vm.activities.count) {
                Button(action: vm.clearFinishedActivities) { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(!vm.canClearActivity).help("Clear finished")
            }
            Divider()
            if vm.activities.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
            } else {
                List(vm.activities) { activity in ActivityRow(activity: activity) }.listStyle(.inset)
            }
        }
    }
}
