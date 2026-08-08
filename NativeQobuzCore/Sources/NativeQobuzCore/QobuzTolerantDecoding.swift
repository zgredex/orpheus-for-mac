import Foundation

/// Decodes optional catalog-presentation fields without allowing one malformed
/// server value to invalidate an otherwise usable release or track.
struct QobuzLossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let consumedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        var consumed = 0
        while !container.isAtEnd {
            consumed += 1
            if let value = try? container.decode(Element.self) {
                values.append(value)
            } else {
                _ = try? container.decode(QobuzJSONFragment.self)
            }
        }
        elements = values
        consumedCount = consumed
    }
}

extension KeyedDecodingContainer {
    func qobuzTolerant<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }

    func qobuzTolerantArray<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> [Value] {
        qobuzTolerant(QobuzLossyArray<Value>.self, forKey: key)?.elements ?? []
    }

    /// Qobuz normally sends booleans, but older and regional payloads can use
    /// 0/1 or textual equivalents. Missing or unrecognized values stay unknown.
    func qobuzAvailabilityFlag(forKey key: Key) -> Bool? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key), value == 0 || value == 1 {
            return value == 1
        }
        if let value = try? decode(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
