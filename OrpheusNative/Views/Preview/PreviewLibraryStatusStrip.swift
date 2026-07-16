import SwiftUI

struct PreviewLibraryStatusStrip: View {
    let status: NativeLibraryStatus

    var body: some View {
        HStack {
            LibraryStatusLabel(status: status)
            Spacer()
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }
}
