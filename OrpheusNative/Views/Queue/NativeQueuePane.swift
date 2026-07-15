import SwiftUI

struct NativeQueuePane: View {
    @EnvironmentObject private var vm: NativeViewModel
    @State private var expandedIDs: Set<UUID> = []

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
                            status: vm.status(for: item),
                            targetQuality: item.downloadQuality ?? vm.settings.quality,
                            libraryStatus: vm.libraryStatus(for: item),
                            isExpanded: expandedIDs.contains(item.id),
                            toggleExpanded: { toggleExpanded(item.id) }
                        )
                            .tag(item.id)
                            .draggable(item.id.uuidString)
                            .dropDestination(for: String.self) { values, _ in
                                guard !vm.isDownloading,
                                      let value = values.first,
                                      let sourceID = UUID(uuidString: value) else { return false }
                                vm.moveQueueItem(sourceID, before: item.id)
                                return true
                            }
                            .contextMenu {
                                Button("Make Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    vm.moveQueueItem(item.id, before: vm.queue.first?.id ?? item.id)
                                }
                                .disabled(vm.isDownloading || vm.queue.first?.id == item.id)
                                Divider()
                                Button("Move Up", systemImage: "arrow.up") { vm.moveQueueItemUp(item.id) }
                                    .disabled(vm.isDownloading || vm.queue.first?.id == item.id)
                                Button("Move Down", systemImage: "arrow.down") { vm.moveQueueItemDown(item.id) }
                                    .disabled(vm.isDownloading || vm.queue.last?.id == item.id)
                                Divider()
                                Button("Remove", systemImage: "trash") { vm.removeQueueItem(item.id) }
                                    .disabled(vm.status(for: item).isActive)
                            }
                    }
                    .onMove(perform: vm.moveQueueItems)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
            vm.selectQueueItem(id)
        }
    }
}
