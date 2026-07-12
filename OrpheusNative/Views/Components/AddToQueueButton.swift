import SwiftUI

/// Small +/checkmark button shared by search rows and browser track/album lists.
struct AddToQueueButton: View {
    let isQueued: Bool
    let add: (() -> Void)?

    var body: some View {
        Button(action: { add?() }) { Image(systemName: isQueued ? "checkmark" : "plus") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(add == nil || isQueued)
            .help(isQueued ? "Already in queue" : "Add to queue")
    }
}
