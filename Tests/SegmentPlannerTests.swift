import XCTest
@testable import YZLLauncher

final class SegmentPlannerTests: XCTestCase {
    func testPlanCoversWholeFileWithoutGaps() {
        let segments = SegmentPlanner.plan(totalBytes: 5_000_000, segmentSize: 1_048_576)
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, 4_999_999)

        var cursor: Int64 = 0
        for segment in segments {
            XCTAssertEqual(segment.start, cursor)
            XCTAssertGreaterThan(segment.length, 0)
            cursor = segment.end + 1
        }
        XCTAssertEqual(cursor, 5_000_000)
    }

    func testPlanIgnoresEmptyAndTinyRequests() {
        XCTAssertTrue(SegmentPlanner.plan(totalBytes: 0, segmentSize: 1_048_576).isEmpty)
        let single = SegmentPlanner.plan(totalBytes: 100, segmentSize: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.length, 100)
    }

    func testHalvesSplitOnlyWhenLargeEnough() {
        let big = DownloadSegment(start: 0, end: 1_048_575)
        let halves = SegmentPlanner.halves(of: big)
        XCTAssertEqual(halves?.count, 2)
        XCTAssertEqual(halves?.first?.length, 524_288)
        XCTAssertEqual(halves?.last?.end, 1_048_575)

        let small = DownloadSegment(start: 0, end: SegmentPlanner.minSegmentLength - 1)
        XCTAssertNil(SegmentPlanner.halves(of: small))
    }

    func testWrittenBytesClampsCorruptParts() {
        let segments = [
            DownloadSegment(start: 0, end: 99),
            DownloadSegment(start: 100, end: 199)
        ]
        let sizes = [
            segments[0].partName: Int64(40),
            segments[1].partName: Int64(500)
        ]
        XCTAssertEqual(SegmentPlanner.writtenBytes(segments: segments, partSizes: sizes), 140)
    }
}
