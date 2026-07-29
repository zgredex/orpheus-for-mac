import SwiftUI

struct CatalogPaginationRow: View {
    let subject: String
    var isLoading = false
    var errorMessage: String?
    var loadMore: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) {
                Spacer()
                paginationContent(compact: false)
                Spacer()
            }
            VStack(spacing: DS.Space.s) {
                paginationContent(compact: true)
            }
        }
        .font(.caption)
        .frame(minHeight: 40)
        .padding(.vertical, DS.Space.xs)
    }

    @ViewBuilder
    private func paginationContent(compact: Bool) -> some View {
        if isLoading {
            ProgressView().controlSize(.small)
            Text("Loading more \(subject)…")
                .foregroundStyle(.secondary)
        } else if let errorMessage {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(errorMessage)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: !compact, vertical: true)
            Button("Try Again") { loadMore?() }
                .controlSize(.small)
        } else {
            Button("Load More", systemImage: "arrow.down.circle") { loadMore?() }
                .controlSize(.small)
        }
    }
}
