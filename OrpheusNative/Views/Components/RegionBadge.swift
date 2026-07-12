import SwiftUI

struct RegionBadge: View {
    let code: String

    var body: some View {
        HStack(spacing: 5) {
            if let flag {
                Text(flag)
                    .font(.system(size: 12))
                    .frame(width: 16, height: 14)
                    .clipped()
            } else {
                Image(systemName: "globe")
                    .font(.caption)
                    .frame(width: 16)
            }
            Text(normalizedCode)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
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
