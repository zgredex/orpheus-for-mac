import Foundation
import XCTest
@testable import NativeQobuzCore

final class FileTransferTests: XCTestCase {
    func testNetworkFailuresDistinguishConnectivityLossFromOrdinaryTimeouts() {
        let offline = NativeQobuzError.networkFailure(URLError(.notConnectedToInternet))
        let lost = NativeQobuzError.networkFailure(URLError(.networkConnectionLost))
        let timeout = NativeQobuzError.networkFailure(URLError(.timedOut))

        XCTAssertTrue(offline.isConnectivityLoss)
        XCTAssertTrue(lost.isConnectivityLoss)
        XCTAssertTrue(offline.canResumeTransfer)
        XCTAssertFalse(timeout.isConnectivityLoss)
        XCTAssertTrue(timeout.canResumeTransfer)
        XCTAssertTrue(NativeQobuzError.http(403, "Expired").requiresFreshSignedURL)
        XCTAssertFalse(NativeQobuzError.http(401, "Unauthorized").requiresFreshSignedURL)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testValidContentRangeAppendsAtExactPartialOffset() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/audio")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 5-10/11"]
        ))

        XCTAssertEqual(
            try fileTransferDisposition(for: response, requestedOffset: 5, alreadyRetriedFresh: false),
            .append(totalBytes: 11)
        )
    }

    func testUnsafeContentRangeRetriesFreshOnlyOnce() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/audio")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 4-10/11"]
        ))

        XCTAssertEqual(
            try fileTransferDisposition(for: response, requestedOffset: 5, alreadyRetriedFresh: false),
            .retryFresh
        )
        XCTAssertThrowsError(
            try fileTransferDisposition(for: response, requestedOffset: 5, alreadyRetriedFresh: true)
        )
    }

    func testRangeTransferAppendsExistingPartialAndInstallsCompletedFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("audio.flac")
        let partial = destination.appendingPathExtension("partial")
        try Data("hello".utf8).write(to: partial)
        let recorder = RequestRecorder()
        StubURLProtocol.handler = { request, client, protocolInstance in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Range": "bytes 5-10/11",
                    "Content-Length": "6"
                ]
            )!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: Data(" world".utf8))
            client.urlProtocolDidFinishLoading(protocolInstance)
        }

        let events = try await collectTransfer(to: destination)

        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=5-")
        XCTAssertEqual(try Data(contentsOf: destination), Data("hello world".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(events.last, .completed(destination))
        XCTAssertTrue(events.contains { event in
            guard case .progress(let progress) = event else { return false }
            return progress.bytesWritten == 11 && progress.totalBytes == 11
        })
    }

    func testIgnoredRangeRestartsCleanlyInsteadOfDuplicatingBytes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("audio.mp3")
        let partial = destination.appendingPathExtension("partial")
        try Data("stale".utf8).write(to: partial)
        StubURLProtocol.handler = { request, client, protocolInstance in
            let body = Data("fresh audio".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: body)
            client.urlProtocolDidFinishLoading(protocolInstance)
        }

        _ = try await collectTransfer(to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("fresh audio".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testNetworkFailurePreservesWrittenPartialBytes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("audio.flac")
        let partial = destination.appendingPathExtension("partial")
        StubURLProtocol.handler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "11"]
            )!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: Data("hello".utf8))
            client.urlProtocolDidFinishLoading(protocolInstance)
        }

        do {
            _ = try await collectTransfer(to: destination)
            XCTFail("Expected the interrupted transfer to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("reach Qobuz"))
        }

        XCTAssertEqual(try Data(contentsOf: partial), Data("hello".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func collectTransfer(to destination: URL) async throws -> [FileTransferEvent] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = URLSessionFileTransferClient(configuration: configuration)
        var events: [FileTransferEvent] = []
        for try await event in client.events(
            from: URL(string: "https://example.test/audio")!,
            to: destination,
            fileSystem: try LibraryFileSystem(rootURL: destination.deletingLastPathComponent())
        ) {
            events.append(event)
        }
        return events
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, URLProtocolClient, URLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let handler = Self.handler else { return }
        handler(request, client, self)
    }

    override func stopLoading() {}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }
}
