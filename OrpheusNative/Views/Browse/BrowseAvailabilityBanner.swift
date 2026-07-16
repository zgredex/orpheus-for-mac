import SwiftUI

struct BrowseAvailabilityBanner: View {
    let availability: NativeBrowseAvailability

    var body: some View {
        switch availability {
        case .unknown(let message):
            banner(message, symbol: "questionmark.circle.fill", color: .blue)
        case .partial(let message):
            banner(message, symbol: "exclamationmark.triangle.fill", color: .orange)
        case .unavailable(let message):
            banner(message, symbol: "nosign", color: .red)
        case .checking, .available:
            EmptyView()
        }
    }

    private func banner(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(color.opacity(0.08))
    }
}
