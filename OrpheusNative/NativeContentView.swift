import AppKit
import NativeQobuzCore
import SwiftUI
import UniformTypeIdentifiers

struct NativeContentView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            NativeInputBar()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            HSplitView {
                NativeQueuePane()
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                VSplitView {
                    Group {
                        if vm.isBrowseOpen { NativeBrowseView() }
                        else { NativePreviewView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                    NativeActivityView()
                        .frame(minHeight: 130, idealHeight: 190)
                }
                .frame(minWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            NativeCommandBar()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                RegionBadge(code: vm.accountRegion)
                Button { vm.showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $vm.showSettings) { NativeSettingsView() }
        .alert("Orpheus Native", isPresented: Binding(
            get: { vm.notice != nil },
            set: { if !$0 { vm.notice = nil } }
        )) {
            Button("OK") { vm.notice = nil }
        } message: {
            Text(vm.notice ?? "")
        }
    }
}

private struct RegionBadge: View {
    let code: String

    var body: some View {
        HStack(spacing: 5) {
            if let flag {
                Text(flag)
                    .font(.system(size: 12))
                    .frame(width: 16, height: 14)
                    .clipped()
            } else {
                Image(systemName: "globe")
                    .font(.caption)
                    .frame(width: 16)
            }
            Text(normalizedCode)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
    }

    private var normalizedCode: String {
        let value = code.uppercased()
        return value.count == 2 ? value : "--"
    }

    private var flag: String? {
        guard normalizedCode.count == 2 else { return nil }
        let scalars = normalizedCode.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return scalars.map(String.init).joined()
    }
}

private struct NativeInputBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Paste Qobuz links or search", text: $vm.input)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(vm.submitInput)
            if !vm.input.isEmpty {
                Button { vm.input = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
            Divider().frame(height: 20)
            Button(action: importText) { Image(systemName: "doc.badge.plus") }
                .help("Import links from text file")
            Button(action: vm.submitInput) { Image(systemName: "arrow.right.circle.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add links or search")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .onAppear { focused = true }
    }

    private func importText() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "m3u")!, UTType(filenameExtension: "m3u8")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { vm.addText(try String(contentsOf: url, encoding: .utf8)) }
        catch { vm.notice = "Could not read the text file: \(error.localizedDescription)" }
    }
}

private struct NativeQueuePane: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.headline)
                Text("\(vm.queue.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: vm.clearQueue) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .disabled(vm.queue.isEmpty)
                    .help("Clear queue")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            Divider()

            if vm.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "music.note.list", description: Text("Paste links or add results from Browse."))
            } else {
                List(selection: Binding(
                    get: { vm.selectedQueueID },
                    set: { vm.selectQueueItem($0) }
                )) {
                    ForEach(vm.queue) { item in
                        QueueRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Remove", systemImage: "trash") { vm.removeQueueItem(item.id) }
                                    .disabled(item.status == .downloading)
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct QueueRow: View {
    let item: NativeQueueItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            statusSymbol
        }
        .frame(minHeight: 38)
    }

    private var icon: String {
        switch item.request {
        case .album: "square.stack"
        case .artist: "person.crop.circle"
        case .playlist: "music.note.list"
        case .track: "music.note"
        }
    }

    private var tint: Color {
        switch item.status {
        case .failed: .red
        case .completed: .green
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    @ViewBuilder private var statusSymbol: some View {
        switch item.status {
        case .loading: ProgressView().controlSize(.small)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .ready: EmptyView()
        }
    }
}

private struct NativePreviewView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        Group {
            switch vm.preview {
            case .empty:
                ContentUnavailableView("Select an item", systemImage: "music.note", description: Text("Metadata and tracks appear here."))
            case .loading:
                ProgressView("Loading Qobuz metadata...")
            case .album(let album):
                AlbumPreview(album: album)
            case .track(let track):
                TrackPreview(track: track)
            case .playlist(let playlist):
                CollectionPreview(title: playlist.name, subtitle: "Playlist", tracks: playlist.tracks)
            case .artist(let artist):
                ArtistPreview(artist: artist)
            case .error(let message):
                ContentUnavailableView("Could not load metadata", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
    }
}

private struct AlbumPreview: View {
    let album: QobuzAlbum

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Artwork(url: album.image?.bestURL, size: 126)
                VStack(alignment: .leading, spacing: 5) {
                    Text(album.displayTitle).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(album.artist.name).font(.headline).foregroundStyle(.secondary)
                    Text(albumMetadata).font(.caption).foregroundStyle(.secondary)
                    if let label = album.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(18)
            Divider()
            List(playableTracks, id: \.id) { track in
                HStack {
                    Text("\(track.trackNumber ?? 0)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    Text(track.displayTitle).lineLimit(1)
                    Spacer()
                    Text(duration(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private var albumMetadata: String {
        [album.releaseDate?.prefix(4).description, album.genre, "\(playableTracks.count) tracks"]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }

    private var playableTracks: [QobuzTrack] {
        album.tracks.filter(\.streamable)
    }
}

private struct TrackPreview: View {
    let track: QobuzTrack

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Artwork(url: track.album?.image?.bestURL, size: 160)
            VStack(alignment: .leading, spacing: 7) {
                Text(track.displayTitle).font(.title2.weight(.semibold))
                Text(track.performer?.name ?? "Unknown Artist").font(.headline).foregroundStyle(.secondary)
                Text(track.album?.title ?? "").foregroundStyle(.secondary)
                if let composer = track.composer?.name { LabeledContent("Composer", value: composer) }
                if let isrc = track.isrc { LabeledContent("ISRC", value: isrc) }
            }
            Spacer()
        }
        .padding(20)
    }
}

private struct CollectionPreview: View {
    let title: String
    let subtitle: String
    let tracks: [QobuzTrack]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text("\(subtitle)  ·  \(playableTracks.count) tracks").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            Divider()
            List(playableTracks, id: \.id) { track in
                HStack {
                    Text(track.performer?.name ?? "Unknown Artist").foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                    Text(track.displayTitle).lineLimit(1)
                    Spacer()
                    Text(duration(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.listStyle(.inset)
        }
    }

    private var playableTracks: [QobuzTrack] {
        tracks.filter(\.streamable)
    }
}

private struct ArtistPreview: View {
    let artist: QobuzArtistCatalog

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name).font(.title2.weight(.semibold))
                    Text("Artist catalog  ·  \(artist.albums.count) albums").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            Divider()
            List(artist.albums, id: \.id) { album in
                HStack(spacing: 10) {
                    Artwork(url: album.image?.bestURL, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.displayTitle).lineLimit(1)
                        Text(album.releaseDate?.prefix(4).description ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(album.tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.inset)
        }
    }
}

private struct NativeBrowseView: View {
    @EnvironmentObject private var vm: NativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Results for")
                        .foregroundStyle(.secondary)
                    Text(vm.browseQuery)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    if vm.isBrowseLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button { vm.closeBrowse() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close Browse")
                }
                HStack(spacing: 12) {
                    Picker("Category", selection: $vm.browseCategory) {
                        ForEach(NativeBrowseCategory.allCases) { category in
                            Text("\(category.rawValue)  \(vm.browseCount(for: category))")
                                .tag(category)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 430)
                    Spacer()
                    Text(vm.browseStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            browseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var browseContent: some View {
        if vm.loadingBrowseCategories.contains(vm.browseCategory) {
            ProgressView("Searching \(vm.browseCategory.rawValue.lowercased())...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.browseErrors[vm.browseCategory] {
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { vm.retryBrowseSearch() }
            }
        } else {
            switch vm.browseCategory {
            case .albums: AlbumSearchList(albums: vm.browseAlbums)
            case .artists: ArtistSearchList(artists: vm.browseArtists)
            case .tracks: TrackSearchList(tracks: vm.browseTracks)
            }
        }
    }
}

private struct AlbumSearchList: View {
    @EnvironmentObject private var vm: NativeViewModel
    let albums: [QobuzAlbumSummary]
    var body: some View {
        List(albums, id: \.id) { album in
            SearchRow(artwork: album.image?.bestURL, title: album.title, subtitle: album.artist?.name ?? "Album") {
                vm.addRequest(.album(album.id), title: album.title)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if albums.isEmpty { emptyResults("albums") } }
    }
}

private struct ArtistSearchList: View {
    @EnvironmentObject private var vm: NativeViewModel
    let artists: [QobuzArtist]
    var body: some View {
        List(artists, id: \.id) { artist in
            SearchRow(artwork: nil, title: artist.name, subtitle: "Artist") {
                if let id = artist.id { vm.addRequest(.artist(id), title: artist.name) }
            }
            .disabled(artist.id == nil)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if artists.isEmpty { emptyResults("artists") } }
    }
}

private struct TrackSearchList: View {
    @EnvironmentObject private var vm: NativeViewModel
    let tracks: [QobuzTrack]
    var body: some View {
        List(tracks, id: \.id) { track in
            SearchRow(artwork: track.album?.image?.bestURL, title: track.displayTitle, subtitle: track.performer?.name ?? track.album?.title ?? "Track") {
                vm.addRequest(.track(track.id), title: track.displayTitle)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if tracks.isEmpty { emptyResults("tracks") } }
    }
}

private struct SearchRow: View {
    let artwork: URL?
    let title: String
    let subtitle: String
    let add: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: artwork, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add to queue")
        }
        .contentShape(Rectangle())
        .frame(minHeight: 52)
    }
}

private func emptyResults(_ category: String) -> some View {
    ContentUnavailableView(
        "No \(category) found",
        systemImage: "magnifyingglass",
        description: Text("Try a different artist, album, or track name.")
    )
}

private struct NativeActivityView: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Text("\(vm.activities.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: vm.clearFinishedActivities) { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(!vm.canClearActivity).help("Clear finished")
            }.padding(.horizontal, 12).frame(height: 38)
            Divider()
            if vm.activities.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
            } else {
                List(vm.activities) { activity in ActivityRow(activity: activity) }.listStyle(.inset)
            }
        }
    }
}

private struct ActivityRow: View {
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
                        Label("\(bytes(Int64(speed)))/s", systemImage: "arrow.down")
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
        guard let total else { return bytes(written) }
        return "\(bytes(written))/\(bytes(total))"
    }
}

private struct NativeCommandBar: View {
    @EnvironmentObject private var vm: NativeViewModel
    var body: some View {
        HStack(spacing: 10) {
            Text(vm.settings.quality == .hiRes ? "Hi-Res FLAC" : vm.settings.quality == .lossless ? "Lossless FLAC" : "MP3 320 kbps")
                .font(.caption.weight(.medium))
            Text(vm.settings.downloadPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Cancel", systemImage: "xmark.circle", action: vm.cancelDownloads).disabled(!vm.canCancel)
            Button("Download Selected", systemImage: "arrow.down.circle", action: vm.downloadSelected)
                .disabled(!vm.canDownloadSelected)
            Button("Download All", systemImage: "arrow.down.circle.fill", action: vm.downloadAll)
                .buttonStyle(.borderedProminent).disabled(!vm.canDownloadAll)
        }
    }
}

private struct NativeSettingsView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = CredentialDraft()
    @State private var quality: QobuzQuality = .hiRes
    @State private var downloadPath = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.weight(.semibold)).padding(.bottom, 16)
            Form {
                Section("Qobuz") {
                    TextField("App ID", text: $credentials.appID)
                    SecureField("App secret", text: $credentials.appSecret)
                    SecureField("Auth token", text: $credentials.authToken)
                    LabeledContent("Account region", value: vm.regionDisplay)
                }
                Section("Download") {
                    Picker("Quality", selection: $quality) {
                        Text("Hi-Res FLAC").tag(QobuzQuality.hiRes)
                        Text("Lossless FLAC").tag(QobuzQuality.lossless)
                        Text("MP3 320 kbps").tag(QobuzQuality.mp3)
                    }
                    LabeledContent("Location") {
                        HStack {
                            Text(downloadPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button { chooseFolder() } label: { Image(systemName: "folder") }.help("Choose download folder")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.top, 8) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!credentials.isComplete || downloadPath.isEmpty)
            }.padding(.top, 14)
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            credentials = vm.credentials
            quality = vm.settings.quality
            downloadPath = vm.settings.downloadPath
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { downloadPath = url.path }
    }

    private func save() {
        do {
            try vm.saveConfiguration(
                credentials: credentials,
                settings: NativeSettings(downloadPath: downloadPath, quality: quality)
            )
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct Artwork: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: Image(systemName: "music.note").font(.title).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(6, size / 8)))
    }
}

private func duration(_ seconds: Int?) -> String {
    guard let seconds else { return "" }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private func bytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: value)
}
