import XCTest
@testable import OrpheusUI

final class OrpheusRunnerTests: XCTestCase {
    func testParsesTqdmProgressLine() throws {
        let line = " 45%|████▌     | 234MB/521MB [00:32<00:41, 6.01MB/s]"
        let event = try XCTUnwrap(OrpheusRunner.parseProgress(line))
        XCTAssertEqual(event.percent, 45)
        XCTAssertEqual(event.downloaded, "234MB")
        XCTAssertEqual(event.total, "521MB")
        XCTAssertEqual(event.speed, "6.01MB/s")
    }

    func testParsesAnsiAndCarriageProgressLine() throws {
        let line = "\u{001B}[32m100%|██████████| 1.5GiB/1.5GiB [00:10<00:00, 140MiB/s]\r"
        let event = try XCTUnwrap(OrpheusRunner.parseProgress(line))
        XCTAssertEqual(event.percent, 100)
        XCTAssertEqual(event.downloaded, "1.5GiB")
        XCTAssertEqual(event.total, "1.5GiB")
        XCTAssertEqual(event.speed, "140MiB/s")
    }

    func testParsesTqdmProgressBeforeSpeedIsKnown() throws {
        let line = "  0%|          | 0.00/14.5M [00:00<?, ?B/s]"
        let event = try XCTUnwrap(OrpheusRunner.parseProgress(line))
        XCTAssertEqual(event.percent, 0)
        XCTAssertEqual(event.downloaded, "0.00")
        XCTAssertEqual(event.total, "14.5M")
        XCTAssertNil(event.speed)
    }

    func testParsesBareTqdmUnitsAndLowercaseSpeed() throws {
        let line = " 45%|████▌     | 234M/521M [00:32<00:41, 6.01kB/s]"
        let event = try XCTUnwrap(OrpheusRunner.parseProgress(line))
        XCTAssertEqual(event.percent, 45)
        XCTAssertEqual(event.downloaded, "234M")
        XCTAssertEqual(event.total, "521M")
        XCTAssertEqual(event.speed, "6.01kB/s")
    }

    func testParsesLiveProgressWithoutWaitingForNextCarriageReturn() throws {
        let events = OrpheusRunner.parseEvents(from: [
            "\r 45%|████▌     | 234M/521M [00:32<00:41, 6.01MB/s]"
        ])
        let progress = try XCTUnwrap(fileProgressEvents(in: events).last)
        XCTAssertEqual(progress.percent, 45)
        XCTAssertEqual(progress.downloaded, "234M")
        XCTAssertEqual(progress.total, "521M")
    }

    func testParsesProgressSplitAcrossChunks() throws {
        let events = OrpheusRunner.parseEvents(from: [
            "Track 2/12\n 45%|████",
            "▌     | 234M/521M [00:32<00:41, 6.01MB/s]\r"
        ])
        let progress = try XCTUnwrap(fileProgressEvents(in: events).last)
        XCTAssertEqual(progress.percent, 45)
        XCTAssertEqual(progress.speed, "6.01MB/s")
    }

    func testFlushesFinalProgressWithoutTrailingCarriageReturn() throws {
        let events = OrpheusRunner.parseEvents(from: [
            "100%|██████████| 521M/521M [00:40<00:00, 12.0MB/s]"
        ])
        let progressEvents = fileProgressEvents(in: events)
        XCTAssertEqual(progressEvents.count, 1)
        XCTAssertEqual(progressEvents.first?.percent, 100)
    }

    func testDoesNotDuplicateLiveProgressWhenDelimiterArrives() {
        let events = OrpheusRunner.parseEvents(from: [
            "\r 45%|████▌     | 234M/521M [00:32<00:41, 6.01MB/s]",
            "\r"
        ])
        XCTAssertEqual(fileProgressEvents(in: events).count, 1)
    }

    func testEmitsOutputLinesAlongsideStructuredProgressEvents() {
        let events = OrpheusRunner.parseEvents(from: [
            "Number of tracks: 12\nTrack 1/12\n 45%|████▌     | 234M/521M [00:32<00:41, 6.01MB/s]\r"
        ])

        XCTAssertTrue(events.contains(.outputLine("Number of tracks: 12")))
        XCTAssertTrue(events.contains(.outputLine("Track 1/12")))
        XCTAssertTrue(events.contains(.trackProgress(.init(
            completed: 0,
            total: 12,
            current: 1,
            state: .started,
            rawLine: "Track 1/12"
        ))))
        XCTAssertEqual(fileProgressEvents(in: events).last?.percent, 45)
    }

    func testIgnoresNonProgressLine() {
        XCTAssertNil(OrpheusRunner.parseProgress("Downloading album cover"))
    }

    func testParsesTrackTotalAndMarker() {
        XCTAssertEqual(OrpheusRunner.parseTrackTotal("Number of tracks: 12"), 12)

        let marker = OrpheusRunner.parseTrackMarker("\u{001B}[32mTrack 3/12")
        XCTAssertEqual(marker?.current, 3)
        XCTAssertEqual(marker?.total, 12)
    }

    func testParsesTrackOutcomeLines() {
        XCTAssertEqual(OrpheusRunner.parseTrackOutcome("=== Track je3x92urb9drs downloaded ==="), .downloaded)
        XCTAssertEqual(OrpheusRunner.parseTrackOutcome("=== Track abc123 skipped ==="), .skipped)
        XCTAssertEqual(OrpheusRunner.parseTrackOutcome("=== Track abc123 failed ==="), .failed)
        XCTAssertNil(OrpheusRunner.parseTrackOutcome("Downloading track file"))
    }

    func testParsesAlbumProgressLines() {
        XCTAssertEqual(OrpheusRunner.parseAlbumTotal("Number of albums: 7"), 7)

        let marker = OrpheusRunner.parseAlbumMarker("\u{001B}[32mAlbum 2/7")
        XCTAssertEqual(marker?.current, 2)
        XCTAssertEqual(marker?.total, 7)

        XCTAssertTrue(OrpheusRunner.parseAlbumOutcome("=== Album Visitor downloaded ==="))
        XCTAssertFalse(OrpheusRunner.parseAlbumOutcome("Downloading album cover"))
    }

    func testSummarizesPythonTracebackToUsefulQobuzError() {
        let output = """
        Traceback (most recent call last):
          File "orpheus_helper.py", line 41, in <module>
            raise SystemExit(main())
          File "orpheus_helper.py", line 36, in main
            runpy.run_path(entrypoint, run_name="__main__")
        urllib.error.HTTPError: HTTP Error 404: Not Found
        """

        XCTAssertEqual(
            OrpheusRunner.summarizeFailureOutput(output),
            "Qobuz could not find this item. It may be unavailable for your account region or no longer downloadable."
        )
    }

    func testSummarizesPythonTracebackToFinalExceptionMessage() {
        let output = """
        Traceback (most recent call last):
          File "orpheus_helper.py", line 41, in <module>
            raise SystemExit(main())
        Exception: Subscription expired
        """

        XCTAssertEqual(OrpheusRunner.summarizeFailureOutput(output), "Subscription expired")
    }

    private func fileProgressEvents(in events: [OrpheusRunner.Event]) -> [OrpheusRunner.ProgressEvent] {
        events.compactMap { event in
            if case .fileProgress(let progress) = event {
                return progress
            }
            return nil
        }
    }
}
