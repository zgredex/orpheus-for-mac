import SwiftUI

struct CatalogPaginationRow: View {
    let subject: String
    var isLoading = false
    var errorMessage: String?
    var loadMore: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Loading more \(subject)…").foregroundStyle(.secondary)
            } else if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(errorMessage).foregroundStyle(.secondary).lineLimit(1)
                Button("Try Again") { loadMore?() }.controlSize(.small)
            } else {
                Button("Load More", systemImage: "arrow.down.circle") { loadMore?() }
                    .controlSize(.small)
            }
            Spacer()
        }
        .font(.caption)
        .frame(minHeight: 40)
    }
}
