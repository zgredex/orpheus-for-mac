import SwiftUI

struct RegionBadge: View {
    let code: String

    var body: some View {
        HStack(spacing: 5) {
            if let flag {
                Text(flag)
                    .font(.system(size: 11))
            } else {
                Image(systemName: "globe")
                    .font(.caption)
            }
            Text(normalizedCode)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .fixedSize()
        .help("Qobuz account region")
    }

    private var normalizedCode: String {
        let value = code.uppercased()
        return value.count == 2 ? value : "--"
    }

    private var flag: String? {
        CountryFlag.emoji(for: normalizedCode)
    }
}
