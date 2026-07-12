import SwiftUI

/// Toolbar chip showing the account region and the active download quality.
/// Rendered as one inline Text so the flag emoji stays inside the system
/// toolbar pill instead of overdrawing a fixed frame.
struct RegionBadge: View {
    let code: String
    let quality: String

    var body: some View {
        (regionText + Text("  ·  \(quality)"))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("Qobuz account region and download quality")
    }

    private var regionText: Text {
        if let flag {
            return Text("\(flag) \(normalizedCode)")
        }
        return Text("\(Image(systemName: "globe")) \(normalizedCode)")
    }

    private var normalizedCode: String {
        let value = code.uppercased()
        return value.count == 2 ? value : "--"
    }

    private var flag: String? {
        CountryFlag.emoji(for: normalizedCode)
    }
}
