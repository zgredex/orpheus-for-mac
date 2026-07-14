import Foundation

func qobuzAllPages<Value>(
    firstItems: [Value],
    firstOffset: Int,
    total: Int,
    pageSize: Int,
    fetch: (Int, Int) async throws -> [Value]
) async throws -> [Value] {
    var items = firstItems
    var offset = firstOffset + firstItems.count
    while offset < total {
        try Task.checkCancellation()
        let page = try await fetch(offset, pageSize)
        guard !page.isEmpty else { break }
        items.append(contentsOf: page)
        offset += page.count
    }
    return items
}
