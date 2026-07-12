import SwiftUI

struct ActivityRow: View {
    @EnvironmentObject private var vm: NativeViewModel
    let activity: NativeDownloadActivity

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    if let speed = activity.bytesPerSecond, speed > 0 {
                        Label("\(Format.bytes(Int64(speed)))/s", systemImage: "arrow.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: activity.progress)
                HStack(spacing: 6) {
                    Text(activity.phase)
                    if activity.totalTracks > 0 { Text("\(activity.completedTracks)/\(activity.totalTracks) tracks") }
                    if let written = activity.bytesWritten { Text(transfer(written, activity.totalBytes)) }
                    if let checksum = activity.checksum { Text("SHA-256 \(checksum.prefix(8))") }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if activity.outputURL != nil {
                Button { vm.reveal(activity) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }.frame(minHeight: 54)
    }

    @ViewBuilder private var statusIcon: some View {
        switch activity.status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }

    private func transfer(_ written: Int64, _ total: Int64?) -> String {
        guard let total else { return Format.bytes(written) }
        return "\(Format.bytes(written))/\(Format.bytes(total))"
    }
}
