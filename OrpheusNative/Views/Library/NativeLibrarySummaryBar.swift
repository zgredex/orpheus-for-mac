import NativeQobuzCore
import SwiftUI

struct NativeLibrarySummaryBar: View {
    let snapshot: QobuzArchiveSnapshot
    let isScanning: Bool
    @Binding var section: NativeLibrarySection

    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.l) {
                Label("\(snapshot.library.entries.count) downloads", systemImage: "tray.full")
                Label("\(snapshot.tracks.count) files", systemImage: "music.note")
                Label("\(snapshot.verifiedCount) verified", systemImage: "checkmark.seal")
                    .foregroundStyle(snapshot.problemCount == 0 ? .green : .secondary)
                if snapshot.problemCount > 0 {
                    Button { section = .problems } label: {
                        Label("\(snapshot.problemCount) problems", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.horizontal, DS.Space.s)
                            .padding(.vertical, DS.Space.xxs)
                            .background(
                                section == .problems ? Color.orange.opacity(0.16) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Show files and index records that need attention")
                }
                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    sectionPicker.frame(width: 600).clipped()
                    Spacer(minLength: DS.Space.m)
                    scanStatus
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    sectionPicker.frame(maxWidth: .infinity).clipped()
                    scanStatus.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .help(snapshot.rootPath)
    }

    private var sectionPicker: some View {
        Picker("Library Section", selection: $section) {
            ForEach(NativeLibraryPresentation.visibleSections(in: snapshot), id: \.self) { value in
                Text("\(value.title)  \(NativeLibraryPresentation.count(value, in: snapshot))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var scanStatus: some View {
        HStack(spacing: DS.Space.xs) {
            if isScanning {
                ProgressView().controlSize(.mini)
                Text("Verifying library…")
            } else {
                Text(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
