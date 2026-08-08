import Foundation

enum QobuzPageCodingKeys: String, CodingKey {
    case items
    case total
    case offset
    case limit
}

protocol QobuzPageItemDecoding {
    associatedtype Item: Decodable

    static func decodeItems(
        from container: KeyedDecodingContainer<QobuzPageCodingKeys>
    ) throws -> (items: [Item], rawCount: Int)
}

enum QobuzStrictPageItems<Item: Decodable>: QobuzPageItemDecoding {
    static func decodeItems(
        from container: KeyedDecodingContainer<QobuzPageCodingKeys>
    ) throws -> (items: [Item], rawCount: Int) {
        let items = try container.decode([Item].self, forKey: .items)
        return (items, items.count)
    }
}

enum QobuzLossyPageItems<Item: Decodable>: QobuzPageItemDecoding {
    static func decodeItems(
        from container: KeyedDecodingContainer<QobuzPageCodingKeys>
    ) throws -> (items: [Item], rawCount: Int) {
        let decoded = try container.decode(QobuzLossyArray<Item>.self, forKey: .items)
        return (decoded.elements, decoded.consumedCount)
    }
}

struct QobuzDecodedPage<ItemDecoder: QobuzPageItemDecoding>: Decodable {
    let items: [ItemDecoder.Item]
    let rawItemCount: Int
    let total: Int?
    let offset: Int?
    let limit: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QobuzPageCodingKeys.self)
        let decodedItems = try ItemDecoder.decodeItems(from: container)
        items = decodedItems.items
        rawItemCount = decodedItems.rawCount
        total = container.qobuzTolerant(Int.self, forKey: .total)
        offset = container.qobuzTolerant(Int.self, forKey: .offset)
        limit = container.qobuzTolerant(Int.self, forKey: .limit)
    }
}

typealias QobuzStrictPage<Item: Decodable> = QobuzDecodedPage<QobuzStrictPageItems<Item>>
typealias QobuzLossyPage<Item: Decodable> = QobuzDecodedPage<QobuzLossyPageItems<Item>>
