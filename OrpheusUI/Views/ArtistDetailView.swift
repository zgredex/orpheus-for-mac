import SwiftUI

struct ArtistDetailView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        if case .artistDetail(let artist, let albums) = vm.browseRoute {
            VStack(spacing: 0) {
                ArtistDetailHeader(artist: artist, albums: albums)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if albums.isEmpty {
                            BrowseDetailMessage(icon: "square.stack", text: "No albums returned for this artist")
                        } else {
                            BrowseRowGroup {
                                ForEach(Array(albums.enumerated()), id: \.element.id.value) { index, album in
                                    ArtistAlbumDetailRow(album: album)
                                    if index < albums.index(before: albums.endIndex) {
                                        Divider().padding(.leading, 70)
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

private struct ArtistDetailHeader: View {
    let artist: QobuzSearchArtist
    let albums: [QobuzAlbumResponse]
    @EnvironmentObject private var vm: MainViewModel

    private var artistID: String? {
        artist.id?.value
    }

    private var cover: String {
        artist.image?.large ?? artist.image?.small ?? artist.image?.thumbnail ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            BrowseArtworkView(url: cover, icon: "person.fill", shape: .circle, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(albums.isEmpty ? "Artist catalog" : "\(albums.count) albums")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: queueArtist) {
                Label("Queue Artist", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(artistID == nil)

            Button(action: downloadArtist) {
                Label("Download Artist", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(artistID == nil)

            Button("Queue Albums") {
                vm.addAllArtistAlbums(albums)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(albums.isEmpty)
            .help("Queue visible albums individually")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func queueArtist() {
        if let artistID {
            vm.addArtistToQueue(artistID)
        }
    }

    private func downloadArtist() {
        if let artistID {
            vm.downloadArtistNow(artistID)
        }
    }
}

private struct ArtistAlbumDetailRow: View {
    let album: QobuzAlbumResponse
    @EnvironmentObject private var vm: MainViewModel

    private var title: String {
        album.title + (album.version.map { " (\($0))" } ?? "")
    }

    private var cover: String {
        album.image?.large ?? album.image?.small ?? album.image?.thumbnail ?? ""
    }

    private var metadata: String {
        var parts: [String] = []
        if let year = album.releaseDateOriginal?.prefix(4), !year.isEmpty {
            parts.append(String(year))
        }
        if let count = album.tracksCount, count > 0 {
            parts.append("\(count) tracks")
        }
        if let label = album.label?.name {
            parts.append(label)
        }
        return parts.joined(separator: "  |  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            BrowseArtworkView(url: cover, icon: "square.stack")

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(metadata.isEmpty ? album.artist.name : metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            BrowseRowActions(
                queueAction: { vm.addAlbumToQueue(album.id.value) },
                downloadAction: { vm.downloadAlbumNow(album.id.value) },
                openAction: { vm.pushAlbum(album) },
                queueHelp: "Queue album",
                downloadHelp: "Download album",
                openHelp: "Open album"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
