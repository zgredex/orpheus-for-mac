import Foundation

/// One formatting boundary shared by every editorial presentation. Qobuz HTML
/// is normalized once, and duplicate catchline/description text is suppressed.
struct EditorialContent {
    let summary: AttributedString?
    let description: AttributedString?

    init(summary: String?, editorialDescription: String?) {
        let summary = EditorialTextFormatter.attributedText(from: summary)
        let description = EditorialTextFormatter.attributedText(from: editorialDescription)
        self.summary = summary
        self.description = Self.plainText(description) == Self.plainText(summary)
            ? nil
            : description
    }

    var isEmpty: Bool {
        summary == nil && description == nil
    }

    var descriptionCanExpand: Bool {
        Self.plainText(description)?.count ?? 0 > 240
    }

    var benefitsFromReader: Bool {
        let characterCount = [summary, description]
            .compactMap(Self.plainText)
            .reduce(0) { $0 + $1.count }
        return characterCount > 180
    }

    static func plainText(_ value: AttributedString?) -> String? {
        value.map { String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
