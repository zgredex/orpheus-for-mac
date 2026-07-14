import SwiftUI

/// A compact, shared home for Qobuz editorial copy. Long notes remain readable
/// without pushing the track list out of the preview.
struct EditorialOverview: View {
    let heading: String
    let summary: String?
    let editorialDescription: String?

    @State private var isExpanded = false

    private var formattedSummary: AttributedString? {
        EditorialTextFormatter.attributedText(from: summary)
    }

    private var formattedDescription: AttributedString? {
        let formatted = EditorialTextFormatter.attributedText(from: editorialDescription)
        guard formatted.map(plainText) != formattedSummary.map(plainText) else { return nil }
        return formatted
    }

    private var hasEditorial: Bool {
        formattedSummary != nil || formattedDescription != nil
    }

    private var canExpand: Bool {
        guard let formattedDescription else { return false }
        return plainText(formattedDescription).count > 240
    }

    var body: some View {
        if hasEditorial {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Label(heading, systemImage: "quote.opening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if canExpand {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                        } label: {
                            Label(
                                isExpanded ? "Show less" : "Read more",
                                systemImage: isExpanded ? "chevron.up" : "chevron.down"
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: 780)

                if let formattedSummary {
                    Text(formattedSummary)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .frame(maxWidth: 780, alignment: .leading)
                        .textSelection(.enabled)
                }

                if let formattedDescription {
                    descriptionView(formattedDescription)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .background(Color.secondary.opacity(0.045))
            Divider()
        }
    }

    @ViewBuilder private func descriptionView(_ description: AttributedString) -> some View {
        if isExpanded, canExpand {
            ScrollView(.vertical) {
                editorialText(description)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 780, minHeight: 80, maxHeight: 190, alignment: .leading)
            .scrollIndicators(.automatic)
        } else {
            editorialText(description)
                .lineLimit(canExpand ? 3 : nil)
        }
    }

    private func editorialText(_ description: AttributedString) -> some View {
        Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .frame(maxWidth: 780, alignment: .leading)
            .textSelection(.enabled)
    }

    private func plainText(_ value: AttributedString) -> String {
        String(value.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
