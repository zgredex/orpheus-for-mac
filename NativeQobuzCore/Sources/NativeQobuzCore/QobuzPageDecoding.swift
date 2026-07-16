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
    ) throws -> [Item]
}

enum QobuzStrictPageItems<Item: Decodable>: QobuzPageItemDecoding {
    static func decodeItems(
        from container: KeyedDecodingContainer<QobuzPageCodingKeys>
    ) throws -> [Item] {
        try container.decode([Item].self, forKey: .items)
    }
}

enum QobuzLossyPageItems<Item: Decodable>: QobuzPageItemDecoding {
    static func decodeItems(
        from container: KeyedDecodingContainer<QobuzPageCodingKeys>
    ) throws -> [Item] {
        try container.decode(QobuzLossyArray<Item>.self, forKey: .items).elements
    }
}

struct QobuzDecodedPage<ItemDecoder: QobuzPageItemDecoding>: Decodable {
    let items: [ItemDecoder.Item]
    let total: Int?
    let offset: Int?
    let limit: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QobuzPageCodingKeys.self)
        items = try ItemDecoder.decodeItems(from: container)
        total = container.qobuzTolerant(Int.self, forKey: .total)
        offset = container.qobuzTolerant(Int.self, forKey: .offset)
        limit = container.qobuzTolerant(Int.self, forKey: .limit)
    }
}

typealias QobuzStrictPage<Item: Decodable> = QobuzDecodedPage<QobuzStrictPageItems<Item>>
typealias QobuzLossyPage<Item: Decodable> = QobuzDecodedPage<QobuzLossyPageItems<Item>>
