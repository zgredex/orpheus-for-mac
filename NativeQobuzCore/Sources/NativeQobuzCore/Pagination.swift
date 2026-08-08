import Foundation

struct QobuzPaginationPage<Value> {
    let items: [Value]
    let reportedLimit: Int?
}

protocol QobuzAlbumPage {
    var albums: [QobuzAlbum] { get }
    var albumsTotal: Int? { get }
    var albumsOffset: Int? { get }
    var albumsLimit: Int? { get }
}

extension QobuzArtistCatalog: QobuzAlbumPage {}
extension QobuzLabelCatalog: QobuzAlbumPage {}

func qobuzAllAlbumPages<Page: QobuzAlbumPage>(
    first: Page,
    pageSize: Int,
    fetch: (Int, Int) async throws -> Page
) async throws -> [QobuzAlbum] {
    try await qobuzAllPages(
        firstItems: first.albums,
        firstOffset: first.albumsOffset ?? 0,
        firstReportedLimit: first.albumsLimit,
        total: first.albumsTotal,
        pageSize: pageSize
    ) { offset, limit in
        let page = try await fetch(offset, limit)
        return QobuzPaginationPage(items: page.albums, reportedLimit: page.albumsLimit)
    }
}

func qobuzAllPages<Value>(
    firstItems: [Value],
    firstOffset: Int,
    firstReportedLimit: Int?,
    total: Int?,
    pageSize: Int,
    fetch: (Int, Int) async throws -> QobuzPaginationPage<Value>
) async throws -> [Value] {
    guard firstOffset >= 0,
          total.map({ $0 >= 0 }) ?? true,
          pageSize > 0 else {
        throw NativeQobuzError.invalidResponse("Qobuz returned invalid pagination metadata.")
    }
    var items = firstItems
    var offset = QobuzPageCursor.nextOffset(
        reportedOffset: firstOffset,
        requestedOffset: firstOffset,
        rawItemCount: firstItems.count,
        total: total,
        requestedLimit: effectivePageSize(
            reportedLimit: firstReportedLimit,
            requestedPageSize: pageSize
        )
    )
    while let currentOffset = offset {
        try Task.checkCancellation()
        let page = try await fetch(currentOffset, pageSize)
        guard !page.items.isEmpty else { break }
        items.append(contentsOf: page.items)
        offset = QobuzPageCursor.nextOffset(
            reportedOffset: currentOffset,
            requestedOffset: currentOffset,
            rawItemCount: page.items.count,
            total: total,
            requestedLimit: effectivePageSize(
                reportedLimit: page.reportedLimit,
                requestedPageSize: pageSize
            )
        )
    }
    return items
}

private func effectivePageSize(
    reportedLimit: Int?,
    requestedPageSize: Int
) -> Int {
    guard let reportedLimit, reportedLimit > 0 else { return requestedPageSize }
    return min(reportedLimit, requestedPageSize)
}
