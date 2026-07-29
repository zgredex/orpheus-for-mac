import NativeQobuzCore
import SwiftUI

struct NativeLibrarySummaryBar: View {
    let snapshot: QobuzArchiveSnapshot
    let isScanning: Bool
    @Binding var section: NativeLibrarySection

    var body: some View {
        VStack(spacing: DS.Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.l) {
                    summaryMetrics
                    Spacer(minLength: 0)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                    alignment: .leading,
                    spacing: DS.Space.s
                ) {
                    summaryMetrics
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    sectionPicker.frame(width: DS.Column.librarySectionPicker).clipped()
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

    @ViewBuilder private var summaryMetrics: some View {
        Label("\(snapshot.library.entries.count) downloads", systemImage: "tray.full")
            .fixedSize()
        Label("\(snapshot.tracks.count) files", systemImage: "music.note")
            .fixedSize()
        Label("\(snapshot.verifiedCount) verified", systemImage: "checkmark.seal")
            .foregroundStyle(snapshot.problemCount == 0 ? .green : .secondary)
            .fixedSize()
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
            .fixedSize()
            .help("Show files and index records that need attention")
        }
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
