import SwiftUI

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    var placeholderSymbol = "music.note"

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill().transition(.opacity)
            default:
                shape.fill(.quaternary)
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .font(isHero ? .largeTitle : .title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(.separator, lineWidth: 0.5))
    }

    private var isHero: Bool { size >= DS.Artwork.hero }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isHero ? DS.Radius.hero : DS.Radius.thumb)
    }
}
