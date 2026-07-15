import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct QobuzAssetResponse: Sendable {
    public let data: Data
    public let mimeType: String?

    public init(data: Data, mimeType: String? = nil) {
        self.data = data
        self.mimeType = mimeType
    }
}

public protocol QobuzAssetFetching: Sendable {
    func fetch(_ url: URL) async throws -> QobuzAssetResponse
}

public struct URLSessionQobuzAssetFetcher: QobuzAssetFetching, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> QobuzAssetResponse {
        let assetID = UUID().uuidString
        let started = Date()
        let metadata = ["assetRequestID": assetID, "host": url.host ?? "unknown", "path": url.path]
        qobuzLog.info("asset.network", "Asset request started", metadata: metadata)
        do {
            let (data, response) = try await session.data(from: url)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                qobuzLog.error(
                    "asset.network",
                    "Asset request returned an HTTP failure",
                    metadata: metadata.merging(["status": String(response.statusCode)]) { _, new in new }
                )
                throw NativeQobuzError.http(response.statusCode, "Asset request failed")
            }
            guard !data.isEmpty else {
                throw NativeQobuzError.invalidResponse("Qobuz returned an empty asset")
            }
            qobuzLog.info(
                "asset.network",
                "Asset request completed",
                metadata: metadata.merging([
                    "responseBytes": String(data.count),
                    "mimeType": response.mimeType ?? "unknown",
                    "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000))
                ]) { _, new in new }
            )
            return QobuzAssetResponse(data: data, mimeType: response.mimeType)
        } catch let error where error.isQobuzCancellation {
            qobuzLog.notice("asset.network", "Asset request cancelled", metadata: metadata)
            throw NativeQobuzError.cancelled
        } catch let error as NativeQobuzError {
            qobuzLog.error("asset.network", "Asset request failed", metadata: metadata, error: error)
            throw error
        } catch {
            qobuzLog.error("asset.network", "Asset request failed", metadata: metadata, error: error)
            throw NativeQobuzError.networkFailure(error)
        }
    }
}
