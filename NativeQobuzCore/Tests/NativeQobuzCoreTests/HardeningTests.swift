import Foundation
import XCTest
@testable import NativeQobuzCore

final class HardeningTests: XCTestCase {
    func testCancellationContractNormalizesTaskCoreAndURLSessionErrors() {
        XCTAssertTrue(CancellationError().isQobuzCancellation)
        XCTAssertTrue(NativeQobuzError.cancelled.isQobuzCancellation)
        XCTAssertTrue(URLError(.cancelled).isQobuzCancellation)
        XCTAssertFalse(URLError(.timedOut).isQobuzCancellation)
    }

    func testFilenameComponentsRespectAPFSByteLimitsForMultibyteText() {
        let title = String(repeating: "🎵東京", count: 100)
        let sanitized = StandardQobuzOutputPlanner().sanitize(title)
        let destinationName = QobuzFilenameComponent.make(
            prefix: "01. ",
            stem: sanitized,
            suffix: " [qobuz-track-id]",
            pathExtension: "flac"
        )
        let destination = URL(fileURLWithPath: "/tmp").appendingPathComponent(destinationName)
        let albumID = QobuzID("album")
        let trackID = QobuzID("track")
        let processing = QobuzDownloadArtifacts.processingURL(
            for: destination,
            formatID: 27,
            albumID: albumID,
            trackID: trackID
        )
        let partial = QobuzDownloadArtifacts.partialURL(
            for: destination,
            formatID: 27,
            albumID: albumID,
            trackID: trackID
        )

        XCTAssertLessThanOrEqual(sanitized.utf8.count, QobuzFilenameComponent.sanitizedStemBytes)
        XCTAssertLessThanOrEqual(destination.lastPathComponent.utf8.count, QobuzFilenameComponent.maximumBytes)
        XCTAssertLessThanOrEqual(processing.lastPathComponent.utf8.count, QobuzFilenameComponent.maximumBytes)
        XCTAssertLessThanOrEqual(partial.lastPathComponent.utf8.count, QobuzFilenameComponent.maximumBytes)
        XCTAssertTrue(destinationName.hasSuffix(" [qobuz-track-id].flac"))
    }

    func testArchivePathContractsRejectTraversalAbsoluteAndNULPaths() throws {
        let root = URL(fileURLWithPath: "/Music", isDirectory: true)

        XCTAssertFalse(QobuzPathSafety.isSafeRelativePath("../outside.flac"))
        XCTAssertFalse(QobuzPathSafety.isSafeRelativePath("/absolute.flac"))
        XCTAssertFalse(QobuzPathSafety.isSafeRelativePath("Album/bad\0name.flac"))
        XCTAssertNil(QobuzPathSafety.containedURL(for: "../outside.flac", in: root))
        XCTAssertEqual(
            QobuzPathSafety.containedURL(for: "Artist/Album/01.flac", in: root)?.path,
            "/Music/Artist/Album/01.flac"
        )
        XCTAssertThrowsError(
            try QobuzPathSafety.relativePath(of: URL(fileURLWithPath: "/Elsewhere/01.flac"), in: root)
        )
    }

    func testChecksumAndM3UContractsHandlePortableVariants() {
        let hash = String(repeating: "a", count: 64)
        let checksums = QobuzChecksumManifest.parse(
            "\(hash) *01. Song.flac\r\ninvalid  ignored.flac\n"
        )
        XCTAssertEqual(checksums, ["01. Song.flac": hash])

        let root = URL(fileURLWithPath: "/Music", isDirectory: true)
        let playlist = root.appendingPathComponent("Playlists/Mix", isDirectory: true)
        let contents = "#EXTM3U\r\n#EXTINF:180,Artist - Song\r\n../../Artist/Album/01. Song.flac\r\n../../../../outside.flac\r\n"
        XCTAssertEqual(
            QobuzM3UPlaylist.resolvedRelativePaths(
                in: contents,
                playlistFolder: playlist,
                libraryRoot: root
            ),
            ["Artist/Album/01. Song.flac"]
        )
    }

    func testReusableAudioIndexLoadsEachRootOnlyOnceAndAcceptsNewEntries() {
        let index = QobuzReusableAudioIndex()
        let root = URL(fileURLWithPath: "/Music", isDirectory: true)
        var loadCount = 0

        let first = index.values(for: root) {
            loadCount += 1
            return ["first": root.appendingPathComponent("first.flac")]
        }
        let second = index.values(for: root) {
            loadCount += 1
            return [:]
        }
        index.store(root.appendingPathComponent("second.flac"), reuseKey: "second", root: root)
        let third = index.values(for: root) {
            loadCount += 1
            return [:]
        }

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(third.keys.sorted(), ["first", "second"])
    }

    func testArtworkValidationRejectsSpoofedAndOversizedImages() throws {
        let validPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let artwork = try EmbeddedArtwork.validated(data: validPNG, mimeType: "image/jpeg")

        XCTAssertEqual(artwork.mimeType, "image/png")
        XCTAssertEqual(artwork.externalFilename, "cover.png")
        XCTAssertThrowsError(
            try EmbeddedArtwork.validated(data: Data("not an image".utf8), mimeType: "image/jpeg")
        )
        XCTAssertThrowsError(
            try EmbeddedArtwork.validated(
                data: Data(repeating: 0, count: EmbeddedArtwork.maximumEmbeddedBytes + 1),
                mimeType: "image/png"
            )
        )
    }

    func testDownloadProgressLimiterBoundsBurstsAndAlwaysEmitsCompletion() {
        var time: TimeInterval = 10
        var limiter = QobuzDownloadProgressLimiter(
            minimumInterval: 0.1,
            minimumFractionDelta: 0.01,
            now: { time }
        )

        XCTAssertTrue(limiter.shouldEmit(fraction: 0.01))
        XCTAssertFalse(limiter.shouldEmit(fraction: 0.011))
        time += 0.11
        XCTAssertTrue(limiter.shouldEmit(fraction: 0.012))
        XCTAssertTrue(limiter.shouldEmit(fraction: 1))
    }

}
