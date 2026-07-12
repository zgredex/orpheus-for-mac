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
        .padding(.leading, 7)
        .padding(.trailing, 2)
    }

    private var normalizedCode: String {
        let value = code.uppercased()
        return value.count == 2 ? value : "--"
    }

    private var flag: String? {
        guard normalizedCode.count == 2 else { return nil }
        let scalars = normalizedCode.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return scalars.map(String.init).joined()
    }
}
