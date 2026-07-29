import SwiftUI

struct NativeLibraryResponsiveRow<Primary: View, Metadata: View, Action: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let primary: Primary
    private let metadata: Metadata
    private let action: Action

    init(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder metadata: () -> Metadata,
        @ViewBuilder action: () -> Action
    ) {
        self.primary = primary()
        self.metadata = metadata()
        self.action = action()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                compactRow
            } else {
                ViewThatFits(in: .horizontal) {
                    regularRow
                        .frame(minWidth: DS.Row.libraryRegularMinimumWidth)
                    compactRow
                }
            }
        }
    }

    private var regularRow: some View {
        HStack(spacing: DS.Space.m) {
            primary
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            metadata
            action
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                primary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                action
            }
            HStack(spacing: DS.Space.m) {
                metadata
                Spacer(minLength: 0)
            }
            .padding(.leading, 24 + DS.Space.m)
        }
        .padding(.vertical, DS.Space.xs)
    }
}
