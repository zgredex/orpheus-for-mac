import SwiftUI

struct LibraryStatusLabel: View {
    let status: NativeLibraryStatus
    var compact = false

    var body: some View {
        Label(compact ? status.compactLabel : status.label, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.hasProblems ? .orange : .green)
            .lineLimit(1)
            .help(status.label)
    }

    private var systemImage: String {
        status.hasProblems ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }
}
