import NativeQobuzCore
import SwiftUI

struct NativeLibraryEntryRow: View {
    let entry: QobuzArchiveEntry
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: NativeLibraryPresentation.icon(for: entry.kind))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.title).fontWeight(.medium).lineLimit(1)
                Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.m)
            QualityBadge(kind: NativeLibraryPresentation.qualityKind(for: entry))
            Text(entry.byteCount.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
            NativeLibraryEntryIntegrityLabel(entry: entry)
            Button(action: onReveal) { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .frame(minHeight: 36)
    }
}

struct NativeLibraryStandaloneTrackRow: View {
    let entry: QobuzArchiveEntry
    let track: QobuzArchiveTrack
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "music.note").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.title).fontWeight(.medium).lineLimit(1)
                Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.m)
            NativeLibraryTrackMetadata(track: track)
            Button(action: onReveal) { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .frame(minHeight: 36)
    }
}

struct NativeLibraryTrackRow: View {
    let track: QobuzArchiveTrack
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(URL(fileURLWithPath: track.relativePath).lastPathComponent).lineLimit(1)
                Text("Qobuz \(track.qobuzTrackID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.m)
            NativeLibraryTrackMetadata(track: track)
            Button(action: onReveal) { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .frame(minHeight: 32)
    }
}

private struct NativeLibraryTrackMetadata: View {
    let track: QobuzArchiveTrack

    var body: some View {
        Group {
            QualityBadge(kind: .archive(track))
            Text(track.byteCount.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—")
            .foregroundStyle(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
            NativeLibraryIntegrityLabel(integrity: track.integrity)
        }
        .font(.caption)
    }
}

private struct NativeLibraryEntryIntegrityLabel: View {
    let entry: QobuzArchiveEntry

    var body: some View {
        let clean = entry.problemCount == 0
        Label(
            clean ? "Verified" : "\(entry.problemCount) issue\(entry.problemCount == 1 ? "" : "s")",
            systemImage: clean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(clean ? .green : .orange)
    }
}
