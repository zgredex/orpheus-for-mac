import SwiftUI

/// Uses otherwise-empty hero space for editorial context without reducing the
/// track list. Long copy opens in a dedicated reader instead of growing the hero.
struct EditorialHeroPanel: View {
    let heading: String
    let summary: String?
    let editorialDescription: String?

    @State private var isReaderPresented = false

    private var editorial: EditorialContent {
        EditorialContent(summary: summary, editorialDescription: editorialDescription)
    }

    var body: some View {
        if !editorial.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Label(heading, systemImage: "quote.opening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if editorial.benefitsFromReader {
                        Button("Read more") { isReaderPresented = true }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }

                if let summary = editorial.summary {
                    Text(summary)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .lineSpacing(2)
                }

                if let description = editorial.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(editorial.summary == nil ? 5 : 3)
                        .lineSpacing(2)
                }

                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            .frame(
                maxWidth: .infinity,
                minHeight: DS.Artwork.hero,
                maxHeight: DS.Artwork.hero,
                alignment: .topLeading
            )
            .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: DS.Radius.hero))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.hero)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
            .popover(isPresented: $isReaderPresented, arrowEdge: .bottom) {
                EditorialReader(heading: heading, editorial: editorial)
            }
        }
    }
}

private struct EditorialReader: View {
    let heading: String
    let editorial: EditorialContent

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Label(heading, systemImage: "quote.opening")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if let summary = editorial.summary {
                        Text(summary)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    if let description = editorial.description {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.l)
        .frame(
            width: DS.Preview.editorialReaderWidth,
            height: DS.Preview.editorialReaderHeight
        )
    }
}
