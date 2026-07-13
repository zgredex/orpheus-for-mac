import SwiftUI

struct NativeQueuePane: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !vm.linkInbox.isEmpty {
                LinkInboxSection()
                Divider()
            }
            PaneHeader(title: "Queue", systemImage: "text.line.first.and.arrowtriangle.forward", count: vm.queue.count) {
                Button(action: vm.clearQueue) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .disabled(vm.queue.isEmpty)
                    .help("Clear queue")
            }
            Divider()

            if vm.queue.isEmpty {
                ContentUnavailableView("Queue Is Empty", systemImage: "music.note.list", description: Text("Paste Qobuz links above, or search to browse the catalog."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { vm.selectedQueueID },
                    set: { vm.selectQueueItem($0) }
                )) {
                    ForEach(vm.queue) { item in
                        QueueRow(
                            item: item,
                            targetQuality: item.downloadQuality ?? vm.settings.quality,
                            libraryStatus: vm.libraryStatus(for: item)
                        )
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
