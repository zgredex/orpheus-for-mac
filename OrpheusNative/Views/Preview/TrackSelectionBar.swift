import SwiftUI

struct TrackSelectionBar: View {
    let selectedCount: Int
    let availableCount: Int
    let selectAll: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Label(
                "\(selectedCount) of \(availableCount) selected",
                systemImage: "checklist"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            Spacer()
            Button("All", action: selectAll)
                .buttonStyle(.borderless)
                .disabled(selectedCount == availableCount)
            Button("None", action: clear)
                .buttonStyle(.borderless)
                .disabled(selectedCount == 0)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(Color.secondary.opacity(0.08))
    }
}
