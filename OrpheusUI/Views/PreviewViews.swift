import SwiftUI

struct AlbumPreviewView: View {
    let info: AlbumPreviewInfo

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 18) {
                CoverArtView(url: info.coverURL)

                VStack(alignment: .leading, spacing: 8) {
                    Text(info.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)

                    Text(info.artist)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        if info.year > 0 { Text(String(info.year)) }
                        Text(info.genre)
                        if info.explicit {
                            Label("Explicit", systemImage: "e.square.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Label("\(info.trackCount) tracks", systemImage: "music.note.list")
                        if let duration = info.duration {
                            Label(formatDuration(duration), systemImage: "clock")
                        }
                    }
                    .font(.subheadline)

                    Label(info.quality, systemImage: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(info.isHiRes ? .orange : .primary)

                    if let upc = info.upc, !upc.isEmpty {
                        Text("UPC \(upc)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackPreviewView: View {
    let info: TrackPreviewInfo

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 18) {
                CoverArtView(url: info.coverURL)

                VStack(alignment: .leading, spacing: 8) {
                    Text(info.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)

                    Text(info.artist)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text("from \(info.albumTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text("Track \(info.trackNumber)")
                        if info.discNumber > 1 { Text("Disc \(info.discNumber)") }
                        if info.year > 0 { Text(String(info.year)) }
                        if info.explicit {
                            Label("Explicit", systemImage: "e.square.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GenericPreviewView: View {
    let url: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Ready to download")
                .font(.title3.weight(.semibold))
            Text(url)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(20)
    }
}

struct ArtistPreviewView: View {
    let info: ArtistPreviewInfo

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 18) {
                if info.coverURL.isEmpty {
                    artistPlaceholder
                } else {
                    CoverArtView(url: info.coverURL)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(info.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)

                    Text("Artist catalog")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if info.albumCount > 0 {
                        Label("\(info.albumCount) albums", systemImage: "square.stack")
                            .font(.subheadline)
                    }

                    Text(info.downloadURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artistPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 172, height: 172)
            .overlay {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
    }
}

struct CollectionPreviewView: View {
    let info: CollectionPreviewInfo

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: info.iconName)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)

            Text(info.title)
                .font(.title3.weight(.semibold))

            Text(info.subtitle)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(20)
    }
}

struct RegionMismatchView: View {
    let yourRegion: String
    let blockedRegion: String?
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "globe.europe.africa")
                .font(.system(size: 46))
                .foregroundStyle(.orange)

            Text("Region Mismatch")
                .font(.title2.weight(.semibold))

            Text(regionMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 10) {
                Label("Qobuz region is tied to the auth token.", systemImage: "checkmark.circle.fill")
                Label("Use Settings to replace credentials for the needed account region.", systemImage: "key.fill")
            }
            .font(.callout)
            .padding(14)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Button(action: vm.openSettings) {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }

    private var regionMessage: String {
        if let blockedRegion, !blockedRegion.isEmpty {
            return "Your current account region is \(yourRegion). This item appears to require \(blockedRegion)."
        }
        return "Your current account region is \(yourRegion). This item is not available for that account."
    }
}

struct CoverArtView: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failure:
                placeholder
            case .empty:
                ProgressView()
                    .frame(width: 172, height: 172)
            @unknown default:
                placeholder
            }
        }
        .frame(width: 172, height: 172)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 3, y: 1)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
    }
}

private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remaining = seconds % 60
    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remaining))"
    }
    return "\(minutes):\(String(format: "%02d", remaining))"
}
