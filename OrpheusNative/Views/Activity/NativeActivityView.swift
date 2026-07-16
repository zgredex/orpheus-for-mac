import SwiftUI

struct NativeActivityView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @State private var expandedActivityIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Activity", count: vm.activities.count) {
                Button(action: vm.clearFinishedActivities) { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(!vm.canClearActivity).help("Clear finished")
            }
            Divider()
            if vm.activities.isEmpty {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("No downloads yet")
                            .font(.callout.weight(.medium))
                        Text("Queued items appear here while downloading.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                List(vm.activities) { activity in
                    ActivityRow(
                        activity: activity,
                        status: vm.status(for: activity),
                        showsDetails: detailExpansion(for: activity.id)
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private func detailExpansion(for activityID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedActivityIDs.contains(activityID) },
            set: { isExpanded in
                if isExpanded { expandedActivityIDs.insert(activityID) }
                else { expandedActivityIDs.remove(activityID) }
            }
        )
    }
}
