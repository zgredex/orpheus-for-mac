import SwiftUI

struct NativeActivityView: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Text("\(vm.activities.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: vm.clearFinishedActivities) { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(!vm.canClearActivity).help("Clear finished")
            }.padding(.horizontal, 12).frame(height: 38)
            Divider()
            if vm.activities.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
            } else {
                List(vm.activities) { activity in ActivityRow(activity: activity) }.listStyle(.inset)
            }
        }
    }
}
