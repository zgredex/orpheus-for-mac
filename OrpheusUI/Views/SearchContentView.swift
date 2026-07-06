import SwiftUI

struct SearchContentView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        if vm.browseRoute.isActive {
            VStack(spacing: 0) {
                BrowseHeaderView()

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.browseRoute {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            SearchResultsView()
        case .artistDetail:
            ArtistDetailView()
        case .albumDetail:
            AlbumDetailView()
        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Dismiss") { vm.dismissBrowse() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BrowseHeaderView: View {
    @EnvironmentObject private var vm: MainViewModel

    var body: some View {
        HStack(spacing: 10) {
            if vm.canBrowseBack {
                Button(action: vm.browseBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Browse")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !vm.browseQuery.isEmpty {
                        Text(vm.browseQuery)
                            .lineLimit(1)
                    }
                    if case .results = vm.browseRoute {
                        BrowseCountText(text: vm.browseCountSummary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: vm.dismissBrowse) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close browse")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct BrowseCountText: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.08), in: Capsule())
    }
}
