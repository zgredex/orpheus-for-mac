import SwiftUI

struct EditorialSectionHeader: View {
    let heading: String
    let actionTitle: String?
    let actionSymbol: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Label(heading, systemImage: "quote.opening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let actionTitle {
                Button(action: action) {
                    if let actionSymbol {
                        Label(actionTitle, systemImage: actionSymbol)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
            }
        }
    }
}
