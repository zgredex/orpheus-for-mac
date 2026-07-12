import SwiftUI

/// Capsule badge for audio quality and content markers.
struct QualityBadge: View {
    enum Kind: Hashable {
        case hiRes(bitDepth: Int?, samplingRate: Double?)
        case explicitContent
    }

    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private var text: String {
        switch kind {
        case .hiRes(let bitDepth, let samplingRate):
            guard let bitDepth, let samplingRate else { return "Hi-Res" }
            let rate = samplingRate.formatted(.number.precision(.fractionLength(0...1)))
            return "Hi-Res \(bitDepth)-Bit / \(rate) kHz"
        case .explicitContent:
            return "E"
        }
    }
}
