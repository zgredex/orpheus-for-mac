import SwiftUI

/// Toolbar chip showing download quality and account region.
/// Draws its own capsule; on macOS 26 the system's shared glass background
/// is hidden for this toolbar item (see NativeContentView), so this capsule
/// is the only pill and always wraps the padded content exactly. The flag
/// emoji sits mid-run inside one Text so its glyph ink cannot escape.
struct RegionBadge: View {
    let code: String
    let quality: String

    var body: some View {
        (Text("\(quality)  ·  ") + regionText)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .help("Download quality and Qobuz account region")
    }

    private var regionText: Text {
        if let flag = CountryFlag.emoji(for: normalizedCode) {
            return Text("\(flag) \(normalizedCode)")
        }
        return Text("\(Image(systemName: "globe")) \(normalizedCode)")
    }

    private var normalizedCode: String {
        let value = code.uppercased()
        return value.count == 2 ? value : "--"
    }
}
