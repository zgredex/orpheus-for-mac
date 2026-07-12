import SwiftUI

struct PaneHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    let count: Int
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.headline)
            } else {
                Text(title).font(.headline)
            }
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Bar.paneHeaderHeight)
    }
}
