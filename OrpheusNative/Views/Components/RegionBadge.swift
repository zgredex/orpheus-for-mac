import NativeQobuzCore
import SwiftUI

/// Toolbar chip showing download quality and account region.
/// Draws its own capsule; on macOS 26 the system's shared glass background
/// is hidden for this toolbar item (see NativeContentView), so this capsule
/// is the only pill and always wraps the padded content exactly. The flag
/// emoji sits mid-run inside one Text so its glyph ink cannot escape.
struct RegionBadge: View {
    let code: String?
    let quality: QobuzQuality

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(qualityKind.color)
            Text(qualityKind.text)
                .foregroundStyle(qualityKind.color)
            Text("·")
                .foregroundStyle(.tertiary)
            regionText
        }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .help("Download quality and Qobuz account region")
    }

    private var qualityKind: QualityBadge.Kind { .target(quality) }

    private var regionText: Text {
        if let flag = CountryFlag.emoji(for: normalizedCode) {
            return Text("\(flag) \(normalizedCode)")
        }
        return Text("\(Image(systemName: "globe")) \(normalizedCode)")
    }

    private var normalizedCode: String {
        let value = code?.uppercased() ?? ""
        return value.count == 2 ? value : "--"
    }
}
