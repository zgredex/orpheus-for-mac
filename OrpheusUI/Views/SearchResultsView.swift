import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            BrowseCategoryBar()

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    resultContent
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        let category = vm.selectedBrowseCategory
        let result = vm.browseResults[category]

        switch result.state {
        case .idle, .loading:
            ProgressView("Searching \(category.label.lowercased())...")
                .frame(maxWidth: .infinity)
                .padding(.top, 52)
        case .failed(let message):
            BrowseMessageView(
                icon: "exclamationmark.triangle",
                title: "Could not load \(category.label.lowercased())",
                message: message
            )
        case .loaded:
            switch category {
            case .albums:
                albumRows(result)
            case .artists:
                artistRows(result.artists)
            case .tracks:
                trackRows(result)
            }
        }
    }

    @ViewBuilder
    private func albumRows(_ result: BrowseCategoryResult) -> some View {
        let albums = result.albums
        if albums.isEmpty {
            BrowseMessageView(
                icon: "square.stack",
                title: result.unavailableCount > 0 ? "No available albums" : "No albums found",
                message: result.unavailableCount > 0
                    ? "Qobuz returned albums that are not available for this account region."
                    : nil
            )
        } else {
            BrowseRowGroup {
                ForEach(Array(albums.enumerated()), id: \.element.id.value) { index, album in
                    BrowseAlbumRow(album: album)
                    if index < albums.index(before: albums.endIndex) {
                        Divider().padding(.leading, 70)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artistRows(_ artists: [QobuzSearchArtist]) -> some View {
        if artists.isEmpty {
            BrowseMessageView(icon: "person.crop.circle", title: "No artists found", message: nil)
        } else {
            BrowseRowGroup {
                ForEach(Array(artists.enumerated()), id: \.element.stableBrowseID) { index, artist in
                    BrowseArtistRow(artist: artist)
                    if index < artists.index(before: artists.endIndex) {
                        Divider().padding(.leading, 70)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackRows(_ result: BrowseCategoryResult) -> some View {
        let tracks = result.tracks
        if tracks.isEmpty {
            BrowseMessageView(
                icon: "music.note",
                title: result.unavailableCount > 0 ? "No available tracks" : "No tracks found",
                message: result.unavailableCount > 0
                    ? "Qobuz returned tracks that are not available for this account region."
                    : nil
            )
        } else {
            BrowseRowGroup {
                ForEach(Array(tracks.enumerated()), id: \.element.id.value) { index, track in
                    BrowseTrackRow(track: track)
                    if index < tracks.index(before: tracks.endIndex) {
                        Divider().padding(.leading, 70)
                    }
                }
            }
        }
    }
}

private struct BrowseCategoryBar: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BrowseCategory.allCases) { category in
                Button(action: { vm.selectBrowseCategory(category) }) {
                    HStack(spacing: 6) {
                        Image(systemName: category.iconName)
                            .imageScale(.small)
                        Text(category.label)
                            .font(.subheadline.weight(.medium))
                        statusText(for: category)
                    }
                    .foregroundStyle(foreground(for: category))
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(background(for: category), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusText(for category: BrowseCategory) -> some View {
        let result = vm.browseResults[category]
        switch result.state {
        case .loading:
            ProgressView()
                .scaleEffect(0.45)
                .frame(width: 12, height: 12)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .loaded:
            Text("\(result.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private func background(for category: BrowseCategory) -> Color {
        vm.selectedBrowseCategory == category
            ? Color.accentColor.opacity(0.16)
            : Color.clear
    }

    private func foreground(for category: BrowseCategory) -> Color {
        vm.selectedBrowseCategory == category ? .accentColor : .primary
    }
}

struct BrowseRowGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.10))
        }
    }
}

private struct BrowseAlbumRow: View {
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
        if album.isBrowseAvailable {
            parts.append(album.browseQualityLabel)
        } else {
            parts.append("Unavailable")
        }
        return parts.joined(separator: "  |  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { vm.pushAlbum(album) }) {
                HStack(spacing: 12) {
                    BrowseArtworkView(url: cover, icon: "square.stack")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(album.artist.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(metadata)
                            .font(.caption2)
                            .foregroundColor(album.isBrowseAvailable ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!album.isBrowseAvailable)
            .help(album.browseUnavailableReason ?? "Open album")

            Spacer(minLength: 10)

            BrowseRowActions(
                queueAction: { vm.addAlbumToQueue(album.id.value) },
                downloadAction: { vm.downloadAlbumNow(album.id.value) },
                openAction: { vm.pushAlbum(album) },
                queueHelp: "Queue album",
                downloadHelp: "Download album",
                openHelp: "Open album",
                isEnabled: album.isBrowseAvailable,
                disabledHelp: album.browseUnavailableReason
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct BrowseArtistRow: View {
    let artist: QobuzSearchArtist
    @EnvironmentObject private var vm: MainViewModel

    private var cover: String {
        artist.image?.large ?? artist.image?.small ?? artist.image?.thumbnail ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openArtist) {
                HStack(spacing: 12) {
                    BrowseArtworkView(url: cover, icon: "person.fill", shape: .circle)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(artist.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text("Artist catalog")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(artist.id?.value == nil)
            .help("Open artist")

            Spacer(minLength: 10)

            BrowseRowActions(
                queueAction: queueArtist,
                downloadAction: downloadArtist,
                openAction: openArtist,
                queueHelp: "Queue artist",
                downloadHelp: "Download artist",
                openHelp: "Open artist",
                isEnabled: artist.id?.value != nil
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func queueArtist() {
        if let id = artist.id?.value {
            vm.addArtistToQueue(id)
        }
    }

    private func downloadArtist() {
        if let id = artist.id?.value {
            vm.downloadArtistNow(id)
        }
    }

    private func openArtist() {
        if let id = artist.id?.value {
            vm.pushArtist(id, name: artist.name)
        }
    }
}

private struct BrowseTrackRow: View {
    let track: QobuzTrackResponse
    @EnvironmentObject private var vm: MainViewModel

    private var title: String {
        track.title + (track.version.map { " (\($0))" } ?? "")
    }

    private var artist: String {
        track.performer?.name ?? track.album.artist?.name ?? "Unknown Artist"
    }

    private var cover: String {
        track.album.image?.large ?? track.album.image?.small ?? track.album.image?.thumbnail ?? ""
    }

    private var metadata: String {
        var parts = [artist, track.album.title]
        if let duration = track.duration, duration > 0 {
            parts.append(formatBrowseDuration(duration))
        }
        return parts.joined(separator: "  |  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            BrowseArtworkView(url: cover, icon: "music.note")

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            BrowseRowActions(
                queueAction: { vm.addTrackToQueue(track.id.value) },
                downloadAction: { vm.downloadTrackNow(track.id.value) },
                openAction: { vm.pushAlbumFromTrack(track) },
                queueHelp: "Queue track",
                downloadHelp: "Download track",
                openHelp: "Open album"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct BrowseRowActions: View {
    let queueAction: () -> Void
    let downloadAction: () -> Void
    let openAction: () -> Void
    let queueHelp: String
    let downloadHelp: String
    let openHelp: String
    var isEnabled: Bool = true
    var disabledHelp: String?

    var body: some View {
        HStack(spacing: 5) {
            Button(action: queueAction) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .disabled(!isEnabled)
            .help(isEnabled ? queueHelp : disabledHelp ?? queueHelp)

            Button(action: downloadAction) {
                Image(systemName: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .frame(width: 24, height: 24)
            .disabled(!isEnabled)
            .help(isEnabled ? downloadHelp : disabledHelp ?? downloadHelp)

            Button(action: openAction) {
                Image(systemName: "chevron.right.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .disabled(!isEnabled)
            .help(isEnabled ? openHelp : disabledHelp ?? openHelp)
        }
        .imageScale(.medium)
    }
}

struct BrowseArtworkView: View {
    enum Shape {
        case rounded
        case circle
    }

    let url: String
    let icon: String
    var shape: Shape = .rounded
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let imageURL = URL(string: url), !url.isEmpty {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
    }

    @ViewBuilder
    private var fallback: some View {
        Color.secondary.opacity(0.12)
            .overlay {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
    }

    private var clipShape: AnyShape {
        switch shape {
        case .rounded:
            AnyShape(RoundedRectangle(cornerRadius: 7))
        case .circle:
            AnyShape(Circle())
        }
    }
}

private struct BrowseMessageView: View {
    let icon: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
    }
}

private extension QobuzAlbumResponse {
    var browseQualityLabel: String {
        let isHiRes = hiresStreamable == true
        let bitDepth = Int(maximumBitDepth ?? 16)
        let sampleRate = maximumSamplingRate ?? 44.1
        return isHiRes ? "\(bitDepth)-bit / \(sampleRate.cleanString)kHz" : "16-bit / 44.1kHz"
    }
}

private func formatBrowseDuration(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remaining = seconds % 60
    return "\(minutes):\(String(format: "%02d", remaining))"
}
