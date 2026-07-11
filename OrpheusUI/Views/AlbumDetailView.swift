import SwiftUI

struct AlbumDetailView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        if case .albumDetail(let album, let tracks) = vm.browseRoute {
            VStack(spacing: 0) {
                AlbumDetailHeader(album: album)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if tracks.isEmpty {
                            BrowseDetailMessage(icon: "music.note.list", text: "No tracks returned for this album")
                        } else {
                            BrowseRowGroup {
                                ForEach(Array(tracks.enumerated()), id: \.element.id.value) { index, track in
                                    AlbumTrackDetailRow(index: index + 1, track: track)
                                    if index < tracks.index(before: tracks.endIndex) {
                                        Divider().padding(.leading, 46)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct AlbumDetailHeader: View {
    let album: AlbumPreviewInfo
    @EnvironmentObject private var vm: MainViewModel

    private var metadata: String {
        var parts: [String] = []
        if album.year > 0 { parts.append(String(album.year)) }
        if album.trackCount > 0 { parts.append("\(album.trackCount) tracks") }
        parts.append(album.quality)
        return parts.joined(separator: "  |  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            BrowseArtworkView(url: album.coverURL, icon: "square.stack", size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: { vm.addAlbumToQueue(album.id) }) {
                Label("Queue", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { vm.downloadAlbumNow(album.id) }) {
                Label("Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AlbumTrackDetailRow: View {
    let index: Int
    let track: QobuzTrackRef
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            Text(track.title)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 10)

            Button(action: { vm.addTrackToQueue(track.id.value) }) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Queue track")

            Button(action: { vm.downloadTrackNow(track.id.value) }) {
                Image(systemName: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Download track")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .qobuzContextMenu(
            url: "https://open.qobuz.com/track/\(track.id.value)",
            queueAction: { vm.addTrackToQueue(track.id.value) },
            downloadAction: { vm.downloadTrackNow(track.id.value) }
        )
    }
}

struct BrowseDetailMessage: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
    }
}
