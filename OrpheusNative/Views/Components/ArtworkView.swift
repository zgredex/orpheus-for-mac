import AppKit
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    var placeholderSymbol = "music.note"
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: Image(systemName: placeholderSymbol).font(.title).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(6, size / 8)))
    }
}
