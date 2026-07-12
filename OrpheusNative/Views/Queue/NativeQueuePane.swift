import SwiftUI

struct NativeQueuePane: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.headline)
                Text("\(vm.queue.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: vm.clearQueue) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .disabled(vm.queue.isEmpty)
                    .help("Clear queue")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            Divider()

            if vm.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "music.note.list", description: Text("Paste links or add results from Browse."))
            } else {
                List(selection: Binding(
                    get: { vm.selectedQueueID },
                    set: { vm.selectQueueItem($0) }
                )) {
                    ForEach(vm.queue) { item in
                        QueueRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Remove", systemImage: "trash") { vm.removeQueueItem(item.id) }
                                    .disabled(item.status == .downloading)
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}
