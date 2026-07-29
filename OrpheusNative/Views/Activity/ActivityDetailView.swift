import SwiftUI

struct ActivityDetailView: View {
    let error: String?
    let warnings: [String]
    let notices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let error {
                section(
                    title: "Error",
                    systemImage: "exclamationmark.circle.fill",
                    tint: .red,
                    messages: [error]
                )
            }
            if !warnings.isEmpty {
                section(
                    title: warnings.count == 1 ? "Warning" : "Warnings",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    messages: warnings
                )
            }
            if !notices.isEmpty {
                section(
                    title: notices.count == 1 ? "Delivery detail" : "Delivery details",
                    systemImage: "info.circle.fill",
                    tint: .blue,
                    messages: notices
                )
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DS.Radius.control))
    }

    private func section(
        title: String,
        systemImage: String,
        tint: Color,
        messages: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(messages.indices, id: \.self) { index in
                Text(messages[index])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
