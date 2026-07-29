import Foundation
import XCTest
@testable import NativeQobuzCore

final class BoundedNetworkTests: XCTestCase {
    func testDeclaredOversizedResponseIsRejectedBeforeBodyAccumulation() async throws {
        let session = stubSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "1048576"]
            )!
            return (response, Data("{}".utf8))
        }
        let loader = BoundedURLSessionDataLoader(session: session)

        do {
            _ = try await loader.data(
                from: URL(string: "https://example.test/catalog")!,
                maximumBytes: 1_024
            )
            XCTFail("Expected an oversized-response error")
        } catch let NativeQobuzError.invalidResponse(message) {
            XCTAssertTrue(message.contains("1024-byte limit"))
            XCTAssertTrue(message.contains("1048576 bytes"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingLimitRejectsChunkedAssetWithoutContentLength() async throws {
        let session = stubSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(repeating: 0x41, count: 17))
        }
        let fetcher = URLSessionQobuzAssetFetcher(session: session)

        do {
            _ = try await fetcher.fetch(
                URL(string: "https://example.test/artwork")!,
                maximumBytes: 16
            )
            XCTFail("Expected an oversized-response error")
        } catch let NativeQobuzError.invalidResponse(message) {
            XCTAssertTrue(message.contains("16-byte limit"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellingAStreamingResponseCancelsItsUnderlyingTask() async throws {
        let started = expectation(description: "Protocol started")
        let stopped = expectation(description: "Protocol stopped")
        StallingURLProtocol.started = { started.fulfill() }
        StallingURLProtocol.stopped = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        let loader = BoundedURLSessionDataLoader(
            session: URLSession(configuration: configuration)
        )
        let task = Task {
            try await loader.data(
                from: URL(string: "https://example.test/stall")!,
                maximumBytes: 1_024
            )
        }
        await fulfillment(of: [started], timeout: 1)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error.isQobuzCancellation)
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    private func stubSession(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        BoundedStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class BoundedStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NativeQobuzError.invalidResponse("Missing bounded-network fixture")
            )
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class StallingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var started: (@Sendable () -> Void)?
    nonisolated(unsafe) static var stopped: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?() }
    override func stopLoading() { Self.stopped?() }
}
