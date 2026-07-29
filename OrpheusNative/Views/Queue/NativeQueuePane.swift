import SwiftUI

struct NativeQueuePane: View {
    @EnvironmentObject private var vm: NativeViewModel
    @EnvironmentObject private var account: NativeAccountController
    @EnvironmentObject private var queue: NativeQueueController
    @EnvironmentObject private var linkInbox: NativeLinkInboxController
    @EnvironmentObject private var library: NativeLibraryController
    @EnvironmentObject private var downloads: NativeDownloadController
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if !linkInbox.items.isEmpty {
                LinkInboxSection()
                Divider()
            }
            PaneHeader(title: "Queue", systemImage: "text.line.first.and.arrowtriangle.forward", count: queue.items.count) {
                Button(action: vm.clearQueue) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .disabled(queue.items.isEmpty)
                    .help("Clear queue")
            }
            Divider()

            if queue.items.isEmpty {
                ContentUnavailableView("Queue Is Empty", systemImage: "music.note.list", description: Text("Paste Qobuz links above, or search to browse the catalog."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { queue.selectedID },
                    set: { vm.selectQueueItem($0) }
                )) {
                    ForEach(queue.items) { item in
                        QueueRow(
                            item: item,
                            status: downloads.status(for: item),
                            targetQuality: item.downloadQuality ?? account.settings.quality,
                            libraryStatus: library.status(for: item),
                            isExpanded: expandedIDs.contains(item.id),
                            toggleExpanded: { toggleExpanded(item.id) }
                        )
                            .tag(item.id)
                            .draggable(item.id.uuidString)
                            .dropDestination(for: String.self) { values, _ in
                                guard !downloads.isDownloading,
                                      let value = values.first,
                                      let sourceID = UUID(uuidString: value) else { return false }
                                vm.moveQueueItem(sourceID, before: item.id)
                                return true
                            }
                            .contextMenu {
                                Button("Make Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    vm.moveQueueItem(item.id, before: queue.items.first?.id ?? item.id)
                                }
                                .disabled(downloads.isDownloading || queue.items.first?.id == item.id)
                                Divider()
                                Button("Move Up", systemImage: "arrow.up") { vm.moveQueueItemUp(item.id) }
                                    .disabled(downloads.isDownloading || queue.items.first?.id == item.id)
                                Button("Move Down", systemImage: "arrow.down") { vm.moveQueueItemDown(item.id) }
                                    .disabled(downloads.isDownloading || queue.items.last?.id == item.id)
                                Divider()
                                Button("Remove", systemImage: "trash") { vm.removeQueueItem(item.id) }
                                    .disabled(downloads.status(for: item).isActive)
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
